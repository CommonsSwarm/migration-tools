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
    event MigrateDao(address _openableApp, address vault1, address vault2);
    event ConvertTokens(address indexed holder, uint256 amount, uint256 vestingId);

    /// State

    TokenManager                        public tokenManager;
    Vault                               public vault1;
    Vault                               public vault2;

    MiniMeToken                         public snapshotToken;
    uint256                             public snapshotBlock;

    uint64                              public vestingStartDate;
    uint64                              public vestingCliffPeriod;
    uint64                              public vestingCompletePeriod;

    mapping(address => bool)            public conversions;

    /// ACL
    bytes32 constant public SETUP_MINTING_ROLE = keccak256("SETUP_MINTING_ROLE");
    bytes32 constant public MIGRATE_ROLE = keccak256("MIGRATE_ROLE");

    /// Errors
    string private constant ERROR_TOKENS_ALREADY_MINTED = "MIGRATION_TOOLS_TOKENS_ALREADY_MINTED";
    string private constant ERROR_MINTING_ALREADY_SETUP = "MIGRATION_TOOLS_MINTING_ALREADY_SETUP";
    string private constant ERROR_MINTING_NOT_SETUP = "MIGRATION_TOOLS_MINTING_NOT_SETUP";
    string private constant ERROR_NO_SNAPSHOT_TOKEN = "MIGRATION_TOOLS_NO_SNAPSHOT_TOKEN";
    string private constant ERROR_INVALID_PCT = "MIGRATION_TOOLS_INVALID_PCT";

    /**
     * @notice Initialize migration tools with `_tokenManager` as token manager and `_vault1` and `_vault2` as vaults
     * @param _tokenManager DAO's token manager which token can be snapshoted and minted in another DAO
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
     * @notice Set up minting for snapshot token `_snapshotToken` with a vesting starting at `@formatDate(_vestingStartDate)`, cliff after `@transformTime(_vestingCliffPeriod, 'best')` (first portion of tokens transferable), and completed vesting at `@formatDate(_vestingStartDate+_vestingCliffPeriod+_vestingCompletePeriod)` (all tokens transferable)
     * @param _snapshotToken Old DAO token which snapshot will be used to mint new DAO tokens
     * @param _vestingStartDate Date the vesting calculations for new token start
     * @param _vestingCliffPeriod Date when the initial portion of new tokens are transferable
     * @param _vestingCompletePeriod Date when all new tokens are transferable
     */
    function setupMinting(
        MiniMeToken _snapshotToken,
        uint64 _vestingStartDate,
        uint64 _vestingCliffPeriod,
        uint64 _vestingCompletePeriod
    )
        external auth(SETUP_MINTING_ROLE)
    {
        require(snapshotBlock == 0, ERROR_MINTING_ALREADY_SETUP);
        require(isContract(_snapshotToken), ERROR_NO_SNAPSHOT_TOKEN);
        snapshotToken = _snapshotToken;
        vestingStartDate = _vestingStartDate == 0 ? getTimestamp64() : _vestingStartDate;
        snapshotBlock = getBlockNumber();
        vestingCliffPeriod = _vestingCliffPeriod;
        vestingCompletePeriod = _vestingCompletePeriod;
    }

    /**
     * @notice Mint tokens based on a previously taken snapshot for many addresses
     * @param _holders List of addresses for whom tokens are going to be minted
     */
    function mintTokens(address[] _holders) external isInitialized {
        require(snapshotBlock != 0, ERROR_MINTING_NOT_SETUP);
        for (uint256 i = 0; i < _holders.length; i++) {
            if (!conversions[_holders[i]]) {
                mintTokens(_holders[i]);
            }
        }
    }

    /**
     * @notice Migrate all `_vaultToken` funds to vaults `_newVault1` (`@formatPct(_pct)`%) and `_newVault2` (rest) and use `_newMigrationApp` to snapshot and mint tokens with vesting starting at `@formatDate(_vestingStartDate)`, cliff after `@transformTime(_vestingCliffPeriod, 'best')` (first portion of tokens transferable), and completed vesting at `@formatDate(_vestingStartDate + _vestingCliffPeriod + _vestingCompletePeriod)` (all tokens transferable)
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

        _transferFunds(_newVault1, _newVault2, _vaultToken, _pct);
        _newMigrationApp.setupMinting(tokenManager.token(), _vestingStartDate, _vestingCliffPeriod, _vestingCompletePeriod);

        emit MigrateDao(_newMigrationApp, _newVault1, _newVault2);
    }

    /**
     * @notice Mint tokens for `_holder` based on previously taken snapshot
     * @param _holder Address for whom the token is minted
     */
    function mintTokens(address _holder) public isInitialized {
        require(snapshotBlock != 0, ERROR_MINTING_NOT_SETUP);
        require(!conversions[_holder], ERROR_TOKENS_ALREADY_MINTED);
        conversions[_holder] = true;

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
        emit ConvertTokens(_holder, amount, vestedId);
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
        uint256 totalFunds = vault1Funds.add(vault2.balance(_token));
        uint256 newVault1Funds = totalFunds.mul(_pct).div(PCT_BASE);
        uint256 newVault2Funds = totalFunds.sub(newVault1Funds);

        if (vault1Funds < newVault1Funds) {
            vault1.transfer(_token, _newVault1, vault1Funds);
            vault2.transfer(_token, _newVault1, newVault1Funds.sub(vault1Funds));
            vault2.transfer(_token, _newVault2, newVault2Funds);
        } else {
            vault1.transfer(_token, _newVault1, newVault1Funds);
            vault1.transfer(_token, _newVault2, vault1Funds.sub(newVault1Funds));
            vault2.transfer(_token, _newVault2, newVault2Funds);
        }
    }
}
