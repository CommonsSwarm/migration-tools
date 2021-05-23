pragma solidity ^0.4.24;

import "@aragon/os/contracts/lib/math/SafeMath.sol";
import "@aragon/os/contracts/lib/math/SafeMath64.sol";
import "@aragon/apps-vault/contracts/Vault.sol";
import "@aragon/apps-token-manager/contracts/TokenManager.sol";


contract MigrationTools is AragonApp {
    using SafeMath for uint256;
    using SafeMath64 for uint64;

    uint256 public constant PCT_BASE = 10 ** 18; // 0% = 0; 1% = 10^16; 100% = 10^18

    /// Events
    event MigrateDao(address _newMigrationTools, address vault1, address vault2);
    event ClaimTokens(address indexed holder, uint256 amount, uint256 vestingId);

    /// State

    TokenManager                        public tokenManager;
    Vault                               public vault1;
    Vault                               public vault2;

    MiniMeToken                         public snapshotToken;
    uint256                             public snapshotBlock;

    uint64                              public vestingStartDate;
    uint64                              public vestingCliffPeriod;
    uint64                              public vestingCompletePeriod;

    mapping(address => bool)            public hasClaimed;

    /// ACL
    bytes32 constant public PREPARE_CLAIMS_ROLE = keccak256("PREPARE_CLAIMS_ROLE");
    bytes32 constant public MIGRATE_ROLE = keccak256("MIGRATE_ROLE");

    /// Errors
    string private constant ERROR_TOKENS_ALREADY_CLAIMED = "MIGRATION_TOOLS_TOKENS_ALREADY_CLAIMED";
    string private constant ERROR_CLAIMS_ALREADY_PREPARED = "MIGRATION_TOOLS_CLAIMS_ALREADY_PREPARED";
    string private constant ERROR_CLAIMS_NOT_PREPARED = "MIGRATION_TOOLS_CLAIMS_NOT_PREPARED";
    string private constant ERROR_NO_SNAPSHOT_TOKEN = "MIGRATION_TOOLS_NO_SNAPSHOT_TOKEN";
    string private constant ERROR_INVALID_PCT = "MIGRATION_TOOLS_INVALID_PCT";
    string private constant ERROR_VAULTS_DO_NOT_MATCH = "MIGRATION_TOOLS_VAULTS_DO_NOT_MATCH";

    /**
     * @notice Initialize migration tools with `_tokenManager` as token manager and `_vault1` and `_vault2` as vaults
     * @param _tokenManager DAO's token manager which token can be snapshoted and claimed in another DAO
     * @param _vault1 DAO's vault 1 which funds can be transfered
     * @param _vault2 DAO's vault 2 (optional)
     */
    function initialize(
        TokenManager _tokenManager,
        Vault _vault1,
        Vault _vault2
    )
        public onlyInit
    {
        tokenManager = _tokenManager;
        vault1 = _vault1;
        vault2 = _vault2;

        initialized();
    }

    /**
     * @notice Prepare claims for snapshot token `_snapshotToken.symbol(): string` with a vesting starting `_vestingStartDate == 0x0 ? 'now' : 'at' + @formatDate(_vestingStartDate)`, cliff after `@transformTime(_vestingCliffPeriod, 'best')` (first portion of tokens transferable), and completed vesting after  `@transformTime(_vestingCompletePeriod, 'best')` (all tokens transferable)
     * @param _snapshotToken Old DAO token which snapshot will be used to claim new DAO tokens
     * @param _vestingStartDate Date the vesting calculations for new token start
     * @param _vestingCliffPeriod Date when the initial portion of new tokens are transferable
     * @param _vestingCompletePeriod Date when all new tokens are transferable
     */
    function prepareClaims(
        MiniMeToken _snapshotToken,
        uint64 _vestingStartDate,
        uint64 _vestingCliffPeriod,
        uint64 _vestingCompletePeriod
    )
        external auth(PREPARE_CLAIMS_ROLE)
    {
        require(snapshotBlock == 0, ERROR_CLAIMS_ALREADY_PREPARED);
        require(isContract(_snapshotToken), ERROR_NO_SNAPSHOT_TOKEN);
        snapshotToken = _snapshotToken;
        vestingStartDate = _vestingStartDate == 0 ? getTimestamp64() : _vestingStartDate;
        snapshotBlock = getBlockNumber();
        vestingCliffPeriod = _vestingCliffPeriod;
        vestingCompletePeriod = _vestingCompletePeriod;
    }

    /**
     * @notice Claim tokens based on a previously taken snapshot for many addresses
     * @param _holders List of addresses for whom tokens are going to be claimed
     */
    function claimForMany(address[] _holders) external isInitialized {
        require(snapshotBlock != 0, ERROR_CLAIMS_NOT_PREPARED);
        for (uint256 i = 0; i < _holders.length; i++) {
            if (!hasClaimed[_holders[i]]) {
                claimFor(_holders[i]);
            }
        }
    }

    /**
     * @notice Migrate all `_vaultToken.symbol(): string` funds to Vaults `_newVault1` (`@formatPct(_pct)`%) and `_newVault2` (rest) using Migration app `_newMigrationApp` to snapshot and claim tokens with a vesting starting `_vestingStartDate == 0 ? 'now' : 'at' + @formatDate(_vestingStartDate)`, ending in `@transformTime(_vestingCompletePeriod, 'best')` (date at which all tokens will be transferable), and having a cliff period of `@transformTime(_vestingCliffPeriod, 'best')` (date at which first portion of tokens will be transferable)
     * @param _newMigrationApp New DAO's migration app
     * @param _newVault1 New DAO's first vault in which some funds will be transfered
     * @param _newVault2 New DAO's second vault in which the rest of funds will be transfered
     * @param _vaultToken Token that is going to be transfered
     * @param _pct Percentage of funds that are going to the first vault  (expressed as a percentage of 10^18; eg. 10^16 = 1%, 10^18 = 100%), the rest goes to the second vault
     * @param _vestingStartDate Date the vesting calculations for the new token start
     * @param _vestingCliffPeriod Date when the initial portion of new tokens are transferable
     * @param _vestingCompletePeriod Date when all new tokens are transferable
     */
    function migrate(
        MigrationTools _newMigrationApp,
        Vault _newVault1,
        Vault _newVault2,
        address _vaultToken,
        uint256 _pct,
        uint64 _vestingStartDate,
        uint64 _vestingCliffPeriod,
        uint64 _vestingCompletePeriod
    )
        external auth(MIGRATE_ROLE)
    {
        require(_pct <= PCT_BASE, ERROR_INVALID_PCT);
        require(_newMigrationApp.vault1() == _newVault1 && _newMigrationApp.vault2() == _newVault2, ERROR_VAULTS_DO_NOT_MATCH);

        _transferFunds(_newVault1, _newVault2, _vaultToken, _pct);
        _newMigrationApp.prepareClaims(tokenManager.token(), _vestingStartDate, _vestingCliffPeriod, _vestingCompletePeriod);

        emit MigrateDao(_newMigrationApp, _newVault1, _newVault2);
    }

    /**
     * @notice Claim tokens for `_holder` based on previously taken snapshot
     * @param _holder Address for whom the token is claimed
     */
    function claimFor(address _holder) public isInitialized {
        require(snapshotBlock != 0, ERROR_CLAIMS_NOT_PREPARED);
        require(!hasClaimed[_holder], ERROR_TOKENS_ALREADY_CLAIMED);
        hasClaimed[_holder] = true;

        uint256 amount = snapshotToken.balanceOfAt(_holder, snapshotBlock);

        tokenManager.issue(amount);
        uint256 vestedId = tokenManager.assignVested(
            _holder,
            amount,
            vestingStartDate,
            vestingStartDate.add(vestingCliffPeriod),
            vestingStartDate.add(vestingCompletePeriod),
            true /* revokable */
        );

        emit ClaimTokens(_holder, amount, vestedId);
    }

    /**
     * @dev Transfer all `_token` from `vault1` and `vault2` to `_newVault1` and `_newVault2`
     * @param _newVault1 Vault 1 of the new DAO
     * @param _newVault2 Vault 2 of the new DAO
     * @param _token Token to be transferred
     * @param _pct Percentage of total funds between vault 1 and vault 2 that will go to `_newVault1`, the rest will go to `_newVault2`
     */
    function _transferFunds(address _newVault1, address _newVault2, address _token, uint256 _pct) internal {
        uint256 vault1Funds = vault1.balance(_token);
        uint256 vault2Funds = vault2.balance(_token);
        uint256 totalFunds = vault1Funds.add(vault2Funds);
        uint256 newVault1Funds = totalFunds.mul(_pct).div(PCT_BASE);
        uint256 newVault2Funds = totalFunds.sub(newVault1Funds);

        if (vault1Funds < newVault1Funds) {
            _transfer(vault1, _token, _newVault1, vault1Funds);
            _transfer(vault2, _token, _newVault1, newVault1Funds.sub(vault1Funds));
            _transfer(vault2, _token, _newVault2, newVault2Funds);
        } else {
            _transfer(vault1, _token, _newVault1, newVault1Funds);
            _transfer(vault1, _token, _newVault2, vault1Funds.sub(newVault1Funds));
            _transfer(vault2, _token, _newVault2, vault2Funds);
        }
    }

    /**
     * @dev Transfer from one vault to another
     * @param _vault Origin vault
     * @param _token Transfered token
     * @param _newVault Destination vault
     * @param _funds Amount of tokens
     */
    function _transfer(Vault _vault, address _token, address _newVault, uint256 _funds) internal {
        if (_funds > 0) {
            _vault.transfer(_token, _newVault, _funds);
        }
    }
}
