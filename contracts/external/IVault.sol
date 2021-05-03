pragma solidity ^0.4.24;

interface IVault {
    
    function transfer(address _token, address _to, uint256 _value) external;
    function balance(address _token) external view returns (uint256);
}
