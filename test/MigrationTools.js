/* global web3, artifacts, contract, before, beforeEach, describe, it, context */
const { assertBn, assertRevert } = require('@aragon/contract-helpers-test/src/asserts')
const { injectWeb3, injectArtifacts, ZERO_ADDRESS, bn } = require('@aragon/contract-helpers-test')
const { ANY_ENTITY, newDao, installNewApp } = require('@aragon/contract-helpers-test/src/aragon-os')
const { assert } = require('chai')
const { hash: namehash } = require('eth-ens-namehash')

injectWeb3(web3)
injectArtifacts(artifacts)

const MigrationTools = artifacts.require('MigrationTools')
const TokenManager = artifacts.require('TokenManager')
const Vault = artifacts.require('Vault')
const MiniMeToken = artifacts.require('MiniMeToken')

contract('MigrationTools', ([root, holder, holder2, anyone]) => {
  let dao1, dao2, migrationToolsBase, tokenManagerBase, vaultBase
  let ISSUE_ROLE, ASSIGN_ROLE, TRANSFER_ROLE, SETUP_MINTING_ROLE, MIGRATE_ROLE

  const WEEK = 7 * 24 * 60 * 60
  const VESTING_CLIFF_PERIOD = 1 * WEEK
  const VESTING_COMPLETE_PERIOD = 4 * WEEK
  const TOKEN_MANAGER_APP_ID = namehash(`token-manager.aragonpm.test`)
  const MIGRATION_TOOLS_APP_ID = namehash(`migration-tools.aragonpm.test`)
  const VAULT_APP_ID = namehash(`vault.aragonpm.eth`)

  const newMigrableDao = async root => {
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
    SETUP_MINTING_ROLE = await migrationToolsBase.SETUP_MINTING_ROLE()
    MIGRATE_ROLE = await migrationToolsBase.MIGRATE_ROLE()
  })

  beforeEach('deploy DAOs with migration tools', async () => {
    dao1 = await newMigrableDao(root)
    dao2 = await newMigrableDao(root)

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
      SETUP_MINTING_ROLE,
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

  describe('Setup minting', async () => {
    it('Reverts without SETUP_MINTING_ROLE', async () => {
      await dao2.acl.revokePermission(ANY_ENTITY, dao2.migrationTools.address, SETUP_MINTING_ROLE)
      await assertRevert(
        dao2.migrationTools.setupMinting(
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
        dao2.migrationTools.setupMinting(root, 0, VESTING_CLIFF_PERIOD, VESTING_COMPLETE_PERIOD),
        'MIGRATION_TOOLS_NO_SNAPSHOT_TOKEN'
      )
    })
    describe('Sets up snapshot and vesting', async () => {
      const now = parseInt(Date.now() / 1000)

      const testSetupMinting = vestingStartDate => {
        let txReceipt
        let token

        beforeEach(async () => {
          token = dao1.token.address
          const tx = await dao2.migrationTools.setupMinting(
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
      context('with defined vesting start date', () => testSetupMinting(now))
      context('without defined vesting start date', () => testSetupMinting(0))
    })
    it('Can not be setup twice', async () => {
      const token = dao1.token.address
      await dao2.migrationTools.setupMinting(
        token,
        0,
        VESTING_CLIFF_PERIOD,
        VESTING_COMPLETE_PERIOD
      )
      await assertRevert(
        dao2.migrationTools.setupMinting(token, 0, VESTING_CLIFF_PERIOD, VESTING_COMPLETE_PERIOD),
        'MIGRATION_TOOLS_MINTING_ALREADY_SETUP'
      )
    })
  })

  describe('Mint tokens', async () => {
    it('Requires previously setup minting')
    it('Tokens can not be converted twice')
    it('Vesting is properly setup')
    it('Can mint for multiple addresses')
  })

  describe('Migrate', async () => {
    it('Requires correct percentage')
    it('Transfers from vault1 to newVault2 when required')
    it('Transfers from vault2 to newVault1 when required')
    it('Sets up minting correctly')
    it('Does not transfer if minting was previously set up')
  })
})
