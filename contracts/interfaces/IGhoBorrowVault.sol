pragma solidity ^0.8.9;

interface IGhoBorrowVault {

    /**
    * @notice Returns the toll amount in stkAAVE that a user needs to pay in order to participate
    * @return The amount of stkAAVE tokens as a toll
    */
    function getToll() external view returns (uint256);

    /**
    * @notice Update the toll amount in stkAAVE
    * @param newToll The new value for the toll
    */
    function setToll(uint256 newToll) external;

    /**
    * @notice Allows a user to participate in the vault, by providing the toll amount
    * @dev The sender must approve the appropriate amount of stkAAVE tokens beforehand
    */
    function enter() external;

    /**
    * @notice Allows a user to exit the vault, and redeem the toll amount
    * @dev The user should close their borrow position first
    */
    function exit() external;
    
    /**
    * @notice Open a position by supplying ETH to Aave and borrowing GHO with 50% LTV
    * @param amount The amount of ETH to use as collateral
    */
    function open(uint256 amount) external;

    /**
    * @notice Close the user position by paying back GHO and withdrawing ETH from Aave
    */
    function close() external;

    /**
    * @notice Liquidate a position by payback the debt of a user on their behalf and claiming collateral
    * @param user The address of the user to liquidate
    */
    function liquidate(address user) external;
}