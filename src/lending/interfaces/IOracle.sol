// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

enum OracleType {
    UNKNOWN, // safeguard against using the default value
    STABLESWAP,
    CRYPTOSWAP
}

interface IOracle {
    function BASE_ASSET() external view returns (address);
    function QUOTE_ASSET() external view returns (address);
    function ORACLE_SCALING_EXPONENT() external view returns (uint256);

    function price() external view returns (uint256);
    function decimals() external view returns (uint8);
}
