pragma solidity ^0.4.24;

import "@aragon/minime/contracts/MiniMeToken.sol";

interface ITokenManager {

    function token() external view returns (MiniMeToken);
    function issue(uint256 _amount) external;
    function assignVested(
        address _receiver,
        uint256 _amount,
        uint64 _start,
        uint64 _cliff,
        uint64 _vested,
        bool _revokable
    ) external returns (uint256);
}
