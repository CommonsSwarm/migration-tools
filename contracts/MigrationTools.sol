pragma solidity ^0.4.24;

import "@aragon/os/contracts/lib/math/SafeMath.sol";
import "@aragon/os/contracts/lib/math/SafeMath64.sol";
//import "@aragon/os/contracts/apps/AragonApp.sol";
import "@aragon/apps-vault/contracts/Vault.sol";
import "@aragon/apps-token-manager/contracts/TokenManager.sol";

contract MigrationTools is AragonApp {
    using SafeMath for uint256;
    using SafeMath64 for uint64;

    uint256 private constant PPM = 1000000; // 0% = 0 * 10 ** 4; 1% = 1 * 10 ** 4; 100% = 100 * 10 ** 4

    /// Events
    event MigrateDao(address _openableApp, address vault1, address vault2);
    event ConvertTokens(address indexed holder, uint256 amount, uint256 vestingId);

    /// State

    TokenManager                        public tokenManager;
    Vault                               public vault1;
    Vault                               public vault2;

    MiniMeToken                         public snapshotToken;
    uint256                             public snapshotBlock;

    uint64                              public openDate;
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

    function setupMinting(
        MiniMeToken _snapshotToken,
        uint64 _openDate,
        uint64 _vestingCliffPeriod,
        uint64 _vestingCompletePeriod
    ) external auth(SETUP_MINTING_ROLE) {
        require(snapshotBlock == 0, ERROR_MINTING_ALREADY_SETUP);
        require(isContract(_snapshotToken), ERROR_NO_SNAPSHOT_TOKEN);
        snapshotToken = _snapshotToken;
        openDate = _openDate == 0 ? getTimestamp64() : _openDate;
        snapshotBlock = getBlockNumber();
        vestingCliffPeriod = _vestingCliffPeriod;
        vestingCompletePeriod = _vestingCompletePeriod;
    }

    function mintTokens(address _holder) public isInitialized {
        require(snapshotBlock != 0, ERROR_MINTING_NOT_SETUP);
        require(!conversions[_holder], ERROR_TOKENS_ALREADY_MINTED);
        conversions[_holder] = true;
    
        uint256 amount = snapshotToken.balanceOfAt(_holder, snapshotBlock);

        tokenManager.issue(amount);
        uint256 vestedId = tokenManager.assignVested(
            _holder,
            amount,
            openDate,
            openDate.add(vestingCliffPeriod),
            openDate.add(vestingCompletePeriod),
            true /* revokable */
        );
        emit ConvertTokens(_holder, amount, vestedId);
    }

    function mintTokens(address[] _holders) external isInitialized {
        require(snapshotBlock != 0, ERROR_MINTING_NOT_SETUP);
        for (uint256 i = 0; i < _holders.length; i++) {
            if (!conversions[_holders[i]]) {
                mintTokens(_holders[i]);
            }
        }
    }

    /**
     * @notice Open `_openableApp` and transfer funds to `_newVault1` and `_newVault2`
     * @param _newMigrationApp App that will be opened when the migration of funds is complete
     * @param _newVault1 Address of the first vault in which funds will be transfered
     * @param _newVault2 Address of the second vault in which funds will be transfered
     * @param _vaultToken Token that is going to be transfered
     * @param _pct Percentage of funds that are going to vault 1 (in PPM)
     */
    function migrate(
        MigrationTools _newMigrationApp,
        Vault _newVault1,
        Vault _newVault2,
        address _vaultToken,
        uint256 _pct,
        uint64 _openDate,
        uint64 _vestingCliffPeriod,
        uint64 _vestingCompletePeriod
    ) external auth(MIGRATE_ROLE) {
        require(_pct <= PPM);

        _transferFunds(_newVault1, _newVault2, _vaultToken, _pct);
        _newMigrationApp.setupMinting(tokenManager.token(), _openDate, _vestingCliffPeriod, _vestingCompletePeriod);

        emit MigrateDao(_newMigrationApp, _newVault1, _newVault2);
    }

    function _transferFunds(address _newVault1, address _newVault2, address _token, uint256 _pct) internal {
        uint256 vault1Funds = vault1.balance(_token);
        uint256 totalFunds = vault1Funds.add(vault2.balance(_token));
        uint256 newVault1Funds = totalFunds.mul(_pct).div(PPM);
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
