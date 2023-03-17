// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "./interfaces/IPool.sol";
import "./interfaces/IAToken.sol";
import "./interfaces/IVariableDebtToken.sol";
import "./interfaces/IPriceOracle.sol";
import "./interfaces/IGhoBorrowVault.sol";

contract GhoBorrowVault is OwnableUpgradeable, IGhoBorrowVault {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /// @notice GHO interest rate mode
    uint256 constant GHO_INTEREST_RATE_STRATEGY = 2;
    
    /// @notice address of stkAAVE contract
    IERC20Upgradeable public stkAAVE;
    
    /// @notice address of AAVE Pool contract
    IPool public Pool;

    /// @notice address of WETH token contract
    IERC20Upgradeable public WETH;

    /// @notice address of WETH aToken contract
    IAToken public aWETH;

    /// @notice address of GHO debt token contract
    IVariableDebtToken public vGHO;

    /// @notice address of GHO token contract
    IERC20Upgradeable public GHO;

    /// @notice address of Aave oracle contract
    IPriceOracle public oracle;

    /// @notice initial index value
    uint256 internal constant INITIAL_INDEX = 1e18;

    /// @notice represents 100% basis point
    uint256 internal constant MAXIMUM_BPS = 10000;

    /// @notice Loan To Value basis point. Value = 50%
    uint256 public constant LTV_BPS = 5000;

    /// @notice Liquidation Threshold basis point. Value = 60%
    uint256 public constant LT_BPS = 6000; // 60%

    /// @notice Liquidation Penalty basis point. Value = 1%
    uint256 public constant LP_BPS = 100; // 1%

    /// @notice toll amount required to enter the pool
    uint256 public toll;

    /// @notice struct to store account info
    struct AccountInfo {
        /// @notice toll user deposited to join the pool
        uint256 toll;
        /// @notice total WETH supplied by user
        uint256 supply;
        /// @notice total GHO borrowed by the user
        uint256 borrow;
        /// @notice user supply index
        uint256 supplyIndex;
        /// @notice user borrow index
        uint256 borrowIndex;
    }

    /// @notice mapping from account address to account info
    mapping (address => AccountInfo) public accounts;

    /// @notice global supply index
    uint256 internal supplyIndex;

    /// @notice global borrow index
    uint256 internal borrowIndex;

    /// @notice total supply interest splitted amount users
    uint256 internal totalSupplyInterestAccrued;

    /// @notice total borrow interest splitted amount users
    uint256 internal totalBorrowInterestAccrued;

    /// @notice total supply of WETH by all users
    uint256 public totalSupply;

    /// @notice total borrow of GHO by all users
    uint256 public totalBorrow;

    function initialize(
        uint256 _toll,
        address _stkAAVE,
        address _Pool,
        address _WETH,
        address _aWETH,
        address _vGHO,
        address _GHO,
        address _oracle
    ) external initializer {
        toll = _toll;
        supplyIndex = INITIAL_INDEX;
        borrowIndex = INITIAL_INDEX;
        totalSupplyInterestAccrued = 0;
        totalBorrowInterestAccrued = 0;

        stkAAVE = IERC20Upgradeable(_stkAAVE);
        Pool =  IPool(_Pool);
        WETH = IERC20Upgradeable(_WETH);
        aWETH = IAToken(_aWETH);
        vGHO = IVariableDebtToken(_vGHO);
        GHO = IERC20Upgradeable(_GHO);
        oracle = IPriceOracle(_oracle);

        __Ownable_init();
    }

    /// @inheritdoc IGhoBorrowVault
    function setToll(uint256 _toll) external onlyOwner {
        toll = _toll;
    }

     /// @inheritdoc IGhoBorrowVault
    function getToll() external view returns(uint256) {
        return toll;
    }

     /// @inheritdoc IGhoBorrowVault
    function enter() external {
        accrueInterest();

        AccountInfo storage account = accounts[msg.sender];
        require(account.toll == 0, "you are already participating in vault");

        stkAAVE.safeTransferFrom(msg.sender, address(this), toll);
        account.toll = toll;
    }

     /// @inheritdoc IGhoBorrowVault
    function exit() external {
        accrueInterest();

        AccountInfo storage account = accounts[msg.sender];
        require(account.toll != 0, "you are not participating in vault");

        stkAAVE.safeTransferFrom(address(this), msg.sender, account.toll);
        account.toll = 0;
    }

     /// @inheritdoc IGhoBorrowVault
    function open(uint256 amount) external {
        accrueInterest();

        AccountInfo storage account = accounts[msg.sender];
        require(account.toll != 0, "you are not participating in vault");
        require(account.supply == 0, "you already have an open position");

        WETH.safeTransferFrom(msg.sender, address(this), amount);
        WETH.safeApprove(address(Pool), amount);
        Pool.supply(address(WETH), amount, address(this), 0);

        account.supply = amount;
        account.supplyIndex = supplyIndex;
        totalSupply += amount;

        uint256 wethAssetPrice = oracle.getAssetPrice(address(WETH));
        uint256 totalValueInUSD = ((wethAssetPrice * amount) / oracle.BASE_CURRENCY_UNIT());
        uint256 totalUSDToBorrow = (totalValueInUSD * LTV_BPS) / MAXIMUM_BPS;

        uint256 ghoAssetPrice = oracle.getAssetPrice(address(GHO));
        uint256 totalGHOToBorrow = (totalUSDToBorrow * oracle.BASE_CURRENCY_UNIT()) / ghoAssetPrice;

        Pool.borrow(address(GHO), totalGHOToBorrow, GHO_INTEREST_RATE_STRATEGY, 0, address(this));
        GHO.safeTransfer(msg.sender, totalGHOToBorrow); 

        account.borrow = totalGHOToBorrow;
        account.borrowIndex = borrowIndex;
        totalBorrow += totalGHOToBorrow;
    }

     /// @inheritdoc IGhoBorrowVault
    function close() external {
        accrueInterest();

        AccountInfo storage account = accounts[msg.sender];
        require(account.toll != 0, "you are not participating in vault");
        require(account.supply != 0, "you don't have any open position");

        (uint borrowBalance, uint supplyBalance) = balanceOf(msg.sender);

        GHO.safeTransferFrom(msg.sender, address(this), borrowBalance);
        GHO.safeApprove(address(Pool), borrowBalance);
        Pool.repay(address(GHO), borrowBalance, GHO_INTEREST_RATE_STRATEGY, address(this));

        totalBorrow -= account.borrow;
        account.borrow = 0;
        account.borrowIndex = 0;

        Pool.withdraw(address(WETH), supplyBalance, address(this));
        WETH.safeTransfer(msg.sender, supplyBalance);
        
        totalSupply -= account.supply;
        account.supply = 0;
        account.supplyIndex = 0;

        _updateInterestAccrued();
    }

     /// @inheritdoc IGhoBorrowVault
    function liquidate(address user) external {
        accrueInterest();

        AccountInfo storage account = accounts[user];
        require(account.toll != 0, "user is not participating in vault");
        require(account.supply != 0, "user doesn't have any open position");

        (uint borrowBalance, uint supplyBalance) = balanceOf(user);

        uint256 wethAssetPrice = oracle.getAssetPrice(address(WETH));
        uint256 ghoAssetPrice = oracle.getAssetPrice(address(GHO));
        uint256 totalSupplyValueInUSD = ((wethAssetPrice * supplyBalance) / oracle.BASE_CURRENCY_UNIT());
        uint256 totalBorrowValueInUSD = ((ghoAssetPrice * borrowBalance) / oracle.BASE_CURRENCY_UNIT());
        uint256 ratio = (totalBorrowValueInUSD * MAXIMUM_BPS) / totalSupplyValueInUSD;

        require(ratio > LT_BPS, "account hasn't reached liquidation threshold");

        GHO.safeTransferFrom(msg.sender, address(this), borrowBalance);
        GHO.safeApprove(address(Pool), borrowBalance);
        Pool.repay(address(GHO), borrowBalance, GHO_INTEREST_RATE_STRATEGY, address(this));

        totalBorrow -= account.borrow;
        account.borrow = 0;
        account.borrowIndex = 0;

        Pool.withdraw(address(WETH), supplyBalance, address(this));
        uint256 borrowValueInWETH = (((ghoAssetPrice * oracle.BASE_CURRENCY_UNIT() / wethAssetPrice)) * borrowBalance) / 1e18;
        uint256 liquidationPenalty = (borrowValueInWETH * LP_BPS) / MAXIMUM_BPS;
        WETH.safeTransfer(msg.sender, borrowValueInWETH + liquidationPenalty);
        WETH.safeTransfer(user, supplyBalance - borrowValueInWETH - liquidationPenalty);

        totalSupply -= account.supply;
        account.supply = 0;
        account.supplyIndex = 0;

        _updateInterestAccrued();
    }

    /**
     * @notice returns the supply and borrow balance of user including interest 
     * @param user account for which we need to find the balances
     * @return borrowBalance borrow balance of user + borrow interest of user
     * @return supplyBalance supply balance of user + supply interest of user
     */
    function balanceOf(address user) public view returns(uint256, uint256) {
        AccountInfo storage account = accounts[user];
        uint256 borrowBalance = (((borrowIndex - account.borrowIndex) * account.borrow) / 1e18) + account.borrow;
        uint256 supplyBalance = (((supplyIndex - account.supplyIndex) * account.supply) / 1e18) + account.supply;
        return (borrowBalance, supplyBalance); 
    }

    /**
     * @notice accrues interest and splits the interest proportionally among the users
     */
    function accrueInterest() public {
        uint256 borrowBalance = vGHO.balanceOf(address(this));
        if(borrowBalance > 0) {
            uint256 borrowInterest = borrowBalance - totalBorrow;
            uint256 splitBorrowInterest = borrowInterest - totalBorrowInterestAccrued;
            uint256 borrowInterestPerToken = (splitBorrowInterest * 1e18) / totalBorrow;
            borrowIndex += borrowInterestPerToken;
            totalBorrowInterestAccrued = borrowInterest;
        }

        uint256 supplyBalance = aWETH.balanceOf(address(this));
        if(supplyBalance > 0) {
            uint256 supplyInterest = supplyBalance - totalSupply;
            uint256 splitSupplyInterest = supplyInterest - totalSupplyInterestAccrued;
            uint256 supplyInterestPerToken = (splitSupplyInterest * 1e18) / totalSupply;
            supplyIndex += supplyInterestPerToken;
            totalSupplyInterestAccrued = supplyInterest;
        }
    }

    /**
     * @notice updates the total interest accrued
     */
    function _updateInterestAccrued() internal {
        uint256 borrowBalance = vGHO.balanceOf(address(this));
        uint256 borrowInterest = borrowBalance - totalBorrow;
        totalBorrowInterestAccrued = borrowInterest;

        uint256 supplyBalance = aWETH.balanceOf(address(this));
        uint256 supplyInterest = supplyBalance - totalSupply;
        totalSupplyInterestAccrued = supplyInterest;
    }
}