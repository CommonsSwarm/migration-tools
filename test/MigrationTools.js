/* global web3, artifacts, contract, before, beforeEach, describe, it, context */
const { assertBn, assertRevert, assertEvent } = require('@aragon/contract-helpers-test/src/asserts')
const {
  injectWeb3,
  injectArtifacts,
  ZERO_ADDRESS,
  bn,
  pct16,
} = require('@aragon/contract-helpers-test')
const { ANY_ENTITY, newDao, installNewApp } = require('@aragon/contract-helpers-test/src/aragon-os')
const { assert } = require('chai')
const { hash: namehash } = require('eth-ens-namehash')

injectWeb3(web3)
injectArtifacts(artifacts)

const MigrationTools = artifacts.require('MigrationTools')
const TokenManager = artifacts.require('TokenManager')
const Vault = artifacts.require('Vault')
const MiniMeToken = artifacts.require('MiniMeToken')
const START_DATE = parseInt(Date.now() / 1000)

contract('MigrationTools', ([root, holder, holder2, anyone]) => {
  let dao1, dao2, migrationToolsBase, tokenManagerBase, vaultBase, fundsToken
  let ISSUE_ROLE, ASSIGN_ROLE, TRANSFER_ROLE, PREPARE_CLAIMS_ROLE, MIGRATE_ROLE

  const WEEK = 7 * 24 * 60 * 60
  const VESTING_CLIFF_PERIOD = 1 * WEEK
  const VESTING_COMPLETE_PERIOD = 4 * WEEK
  const TOKEN_MANAGER_APP_ID = namehash(`token-manager.aragonpm.test`)
  const MIGRATION_TOOLS_APP_ID = namehash(`migration-tools.aragonpm.test`)
  const VAULT_APP_ID = namehash(`vault.aragonpm.eth`)

  const newMigrableDao = async (initialDistribution = {}) => {
    const { dao, acl } = await newDao(root)
    const tokenManager = await TokenManager.at(
      await installNewApp(dao, TOKEN_MANAGER_APP_ID, tokenManagerBase.address, root)
    )
    const migrationTools = await MigrationTools.at(
      await installNewApp(dao, MIGRATION_TOOLS_APP_ID, migrationToolsBase.address, root)
    )
    const vault1 = await Vault.at(await installNewApp(dao, VAULT_APP_ID, vaultBase.address, root))
    const vault2 = await Vault.at(await installNewApp(dao, VAULT_APP_ID, vaultBase.address, root))

    const token = await MiniMeToken.new(ZERO_ADDRESS, ZERO_ADDRESS, 0, 'n', 0, 'n', true)
    for (const [holder, amount] of Object.entries(initialDistribution)) {
      await token.generateTokens(holder, amount)
    }
    await token.changeController(tokenManager.address)
    await tokenManager.initialize(token.address, true, 0)
    await vault1.initialize()
    await vault2.initialize()
    await migrationTools.initialize(tokenManager.address, vault1.address, vault2.address)
    return { dao, acl, tokenManager, token, vault1, vault2, migrationTools }
  }

  before('load roles', async () => {
    migrationToolsBase = await MigrationTools.new()
    tokenManagerBase = await TokenManager.new()
    vaultBase = await Vault.new()
    ISSUE_ROLE = await tokenManagerBase.ISSUE_ROLE()
    ASSIGN_ROLE = await tokenManagerBase.ASSIGN_ROLE()
    TRANSFER_ROLE = await vaultBase.TRANSFER_ROLE()
    PREPARE_CLAIMS_ROLE = await migrationToolsBase.PREPARE_CLAIMS_ROLE()
    MIGRATE_ROLE = await migrationToolsBase.MIGRATE_ROLE()
  })

  beforeEach('deploy DAOs with migration tools', async () => {
    dao1 = await newMigrableDao({ [root]: 100, [holder]: 90, [holder2]: 10 })
    dao2 = await newMigrableDao()

    await dao1.acl.createPermission(
      dao1.migrationTools.address,
      dao1.vault1.address,
      TRANSFER_ROLE,
      root,
      { from: root }
    )
    await dao1.acl.createPermission(
      dao1.migrationTools.address,
      dao1.vault2.address,
      TRANSFER_ROLE,
      root,
      { from: root }
    )
    await dao1.acl.createPermission(ANY_ENTITY, dao1.migrationTools.address, MIGRATE_ROLE, root, {
      from: root,
    })

    await dao2.acl.createPermission(
      dao2.migrationTools.address,
      dao2.tokenManager.address,
      ISSUE_ROLE,
      root,
      { from: root }
    )
    await dao2.acl.createPermission(
      dao2.migrationTools.address,
      dao2.tokenManager.address,
      ASSIGN_ROLE,
      root,
      { from: root }
    )
    await dao2.acl.createPermission(
      ANY_ENTITY,
      dao2.migrationTools.address,
      PREPARE_CLAIMS_ROLE,
      root,
      { from: root }
    )
  })

  describe('Initialization', async () => {
    it('Initializes correctly', async () => {
      assert.strictEqual(await dao1.migrationTools.tokenManager(), dao1.tokenManager.address)
      assert.strictEqual(await dao1.migrationTools.vault1(), dao1.vault1.address)
      assert.strictEqual(await dao1.migrationTools.vault2(), dao1.vault2.address)
    })
    it('Can not be initialized again', async () => {
      await assertRevert(
        dao1.migrationTools.initialize(
          dao1.tokenManager.address,
          dao1.vault1.address,
          dao1.vault2.address
        ),
        'INIT_ALREADY_INITIALIZED'
      )
    })
  })

  describe('Prepare claims', async () => {
    it('Reverts without PREPARE_CLAIMS_ROLE', async () => {
      await dao2.acl.revokePermission(ANY_ENTITY, dao2.migrationTools.address, PREPARE_CLAIMS_ROLE)
      await assertRevert(
        dao2.migrationTools.prepareClaims(
          await dao1.tokenManager.token(),
          0,
          VESTING_CLIFF_PERIOD,
          VESTING_COMPLETE_PERIOD
        ),
        'APP_AUTH_FAILED'
      )
    })
    it('Reverts if incorrect snapshot token', async () => {
      await assertRevert(
        dao2.migrationTools.prepareClaims(root, 0, VESTING_CLIFF_PERIOD, VESTING_COMPLETE_PERIOD),
        'MIGRATION_TOOLS_NO_SNAPSHOT_TOKEN'
      )
    })
    describe('Sets up snapshot and vesting', async () => {
      const testPrepareClaims = vestingStartDate => {
        let txReceipt
        let token

        beforeEach(async () => {
          token = dao1.token.address
          const tx = await dao2.migrationTools.prepareClaims(
            token,
            vestingStartDate,
            VESTING_CLIFF_PERIOD,
            VESTING_COMPLETE_PERIOD
          )
          txReceipt = tx.receipt
        })

        it('snapshot token', async () => {
          assert.strictEqual(await dao2.migrationTools.snapshotToken(), token)
        })
        it('snapshot block', async () => {
          assertBn(await dao2.migrationTools.snapshotBlock(), bn(txReceipt.blockNumber))
        })
        it('vesting start date', async () => {
          if (vestingStartDate === 0) {
            vestingStartDate = (await web3.eth.getBlock(txReceipt.blockHash)).timestamp
          }
          assertBn(await dao2.migrationTools.vestingStartDate(), bn(vestingStartDate))
        })
        it('vesting cliff period', async () => {
          assertBn(await dao2.migrationTools.vestingCliffPeriod(), VESTING_CLIFF_PERIOD)
        })
        it('vesting complete period', async () => {
          assertBn(await dao2.migrationTools.vestingCompletePeriod(), bn(VESTING_COMPLETE_PERIOD))
        })
      }
      context('with defined vesting start date', () => testPrepareClaims(START_DATE))
      context('without defined vesting start date', () => testPrepareClaims(0))
    })
    it('Can not be setup twice', async () => {
      const token = dao1.token.address
      await dao2.migrationTools.prepareClaims(
        token,
        0,
        VESTING_CLIFF_PERIOD,
        VESTING_COMPLETE_PERIOD
      )
      await assertRevert(
        dao2.migrationTools.prepareClaims(token, 0, VESTING_CLIFF_PERIOD, VESTING_COMPLETE_PERIOD),
        'MIGRATION_TOOLS_CLAIMS_ALREADY_PREPARED'
      )
    })
  })

  describe('Claim tokens', async () => {
    it('Requires claims previously prepared', async () => {
      await assertRevert(dao2.migrationTools.claimFor(root), 'MIGRATION_TOOLS_CLAIMS_NOT_PREPARED')
    })
    it('Tokens can not be converted twice', async () => {
      const token = dao1.token.address
      await dao2.migrationTools.prepareClaims(
        token,
        0,
        VESTING_CLIFF_PERIOD,
        VESTING_COMPLETE_PERIOD
      )
      await dao2.migrationTools.claimFor(root)
      await assertRevert(
        dao2.migrationTools.claimFor(root),
        'MIGRATION_TOOLS_TOKENS_ALREADY_CLAIMED'
      )
    })
    describe('Vesting', async () => {
      let vesting
      beforeEach(async () => {
        const token = dao1.token.address
        await dao2.migrationTools.prepareClaims(
          token,
          START_DATE,
          VESTING_CLIFF_PERIOD,
          VESTING_COMPLETE_PERIOD
        )
        assertBn(await dao2.token.balanceOf(root), bn(0))
        await dao2.migrationTools.claimFor(root)
        assertBn(await dao2.token.balanceOf(root), bn(100))
        vesting = await dao2.tokenManager.getVesting(root, 0)
      })
      it('amount', async () => {
        assertBn(vesting.amount, bn(100))
      })
      it('start date', async () => {
        assertBn(vesting.start, bn(START_DATE))
      })
      it('cliff date', async () => {
        assertBn(vesting.cliff, bn(START_DATE + VESTING_CLIFF_PERIOD))
      })
      it('vesting date', async () => {
        assertBn(vesting.vesting, bn(START_DATE + VESTING_COMPLETE_PERIOD))
      })
      it('is revokable', async () => {
        assert.isTrue(vesting.revokable)
      })
    })
    it('Emits a ClaimTokens event', async () => {
      await dao2.migrationTools.prepareClaims(
        dao1.token.address,
        0,
        VESTING_CLIFF_PERIOD,
        VESTING_COMPLETE_PERIOD
      )
      const txReceipt = await dao2.migrationTools.claimFor(root)
      assertEvent(txReceipt, 'ClaimTokens')
    })
    it('Can claim for multiple addresses', async () => {
      const token = dao1.token.address
      await dao2.migrationTools.prepareClaims(
        token,
        0,
        VESTING_CLIFF_PERIOD,
        VESTING_COMPLETE_PERIOD
      )
      await dao2.migrationTools.claimForMany([root, holder, holder2])
    })
    it('Can perform after all tokens are claimed', async () => {
      const token = dao1.token.address
      await dao2.migrationTools.prepareClaims(
        token,
        0,
        VESTING_CLIFF_PERIOD,
        VESTING_COMPLETE_PERIOD
      )
      await dao2.migrationTools.claimForMany([root, holder])
      assert.isFalse(await dao2.migrationTools.canPerform(ZERO_ADDRESS, ZERO_ADDRESS, '0x', []))
      await dao2.migrationTools.claimFor(holder2)
      assert.isTrue(await dao2.migrationTools.canPerform(ZERO_ADDRESS, ZERO_ADDRESS, '0x', []))
    })
  })

  describe('Migrate', async () => {
    const TOTAL_FUNDS = 100
    const performMigration = async pct => {
      return dao1.migrationTools.migrate(
        dao2.migrationTools.address,
        dao2.vault1.address,
        dao2.vault2.address,
        fundsToken.address,
        pct16(pct),
        START_DATE,
        VESTING_CLIFF_PERIOD,
        VESTING_COMPLETE_PERIOD
      )
    }
    const checkMigrationTransfers = async distributionPct => {
      // Initial state: vault1 = 30%, vault2 = 70%
      await performMigration(distributionPct)
      // Final state: newVault1 = ${pct}%, newVault2 = ${100-pct}%
      assertBn(
        await dao2.vault1.balance(fundsToken.address),
        bn((TOTAL_FUNDS * distributionPct) / 100)
      )
      assertBn(
        await dao2.vault2.balance(fundsToken.address),
        bn((TOTAL_FUNDS * (100 - distributionPct)) / 100)
      )
    }
    beforeEach(async () => {
      fundsToken = await MiniMeToken.new(ZERO_ADDRESS, ZERO_ADDRESS, 0, 'n', 0, 'n', true)
      await fundsToken.generateTokens(dao1.vault1.address, TOTAL_FUNDS * 0.3)
      await fundsToken.generateTokens(dao1.vault2.address, TOTAL_FUNDS * 0.7)
    })
    it('Requires correct percentage', async () => {
      await assertRevert(performMigration(101), 'MIGRATION_TOOLS_INVALID_PCT')
    })
    it('Transfers from vault1 to newVault2 when required', () => checkMigrationTransfers(10))
    it('Transfers from vault2 to newVault1 when required', () => checkMigrationTransfers(40))
    it('Transfers all from vault1 and vault2 to newVault1', () => checkMigrationTransfers(100))
    it('Transfers all from vault1 and vault2 to newVault2', () => checkMigrationTransfers(0))
    it('Prepare claims correctly', async () => {
      await performMigration(50)
      assert.strictEqual(await dao2.migrationTools.snapshotToken(), dao1.token.address)
      assertBn(await dao2.migrationTools.vestingStartDate(), bn(START_DATE))
      assertBn(await dao2.migrationTools.vestingCliffPeriod(), bn(VESTING_CLIFF_PERIOD))
      assertBn(await dao2.migrationTools.vestingCompletePeriod(), bn(VESTING_COMPLETE_PERIOD))
    })
    it('Emits a MigrateDao event', async () => {
      const migrateReceipt = await performMigration(50)
      assertEvent(migrateReceipt, 'MigrateDao')
    })
    it('Does not migrate if claims are already prepared', async () => {
      await dao2.migrationTools.prepareClaims(
        fundsToken.address,
        START_DATE,
        VESTING_CLIFF_PERIOD,
        VESTING_COMPLETE_PERIOD
      )
      await assertRevert(
        dao1.migrationTools.migrate(
          dao2.migrationTools.address,
          dao2.vault1.address,
          dao2.vault2.address,
          fundsToken.address,
          pct16(50),
          START_DATE,
          VESTING_CLIFF_PERIOD,
          VESTING_COMPLETE_PERIOD
        ),
        'MIGRATION_TOOLS_CLAIMS_ALREADY_PREPARED'
      )
    })
  })
})
