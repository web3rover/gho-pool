import { loadFixture, mine } from "@nomicfoundation/hardhat-network-helpers";
import { ethers, network, upgrades } from "hardhat";
import { GhoBorrowVault, GhoBorrowVault__factory, IAaveOracle__factory, IERC20__factory, IPool__factory, MockAggregator, MockAggregator__factory } from "../typechain-types";
import { expect } from "chai";

const POOL_ADDRESS = "0x617Cf26407193E32a771264fB5e9b8f09715CdfB"
const GHO_UNDERLYING_ADDRESS = "0xcbE9771eD31e761b744D3cB9eF78A1f32DD99211"
const WETH_ADDRESS = "0x84ced17d95F3EC7230bAf4a369F1e624Ae60090d"
const stkAAVE_ADDRESS = "0xb85B34C58129a9a7d54149e86934ed3922b05592"
const ORACLE_ADDRESS = "0xcb601629B36891c43943e3CDa2eB18FAc38B5c4e"
const aWETH_ADDRESS = "0x49871B521E44cb4a34b2bF2cbCF03C1CF895C48b"

const WETH_FAUCET_ADDRESS = "0x5c4220e10d0D835e9eDf04061379dED26E845bA8"
const POOL_ADMIN = "0x2892e37624Ec31CC42502f297821109700270971"
const stkAAVE_FAUCET_ADDRESS = "0xc1aB66d22a76E7C5D71B7CF22cec878987b9847B"
const GHO_FAUCET_ADDRESS = "0x40D17dAdcDE03776F1bCb27297c108A788c59Edc"

const GBH_INTEREST_RATE_STRATEGY = 2
const BIGNUMBER8 = ethers.BigNumber.from("100000000"); // 1e8

const toWei = (amount: string): string => {
  return ethers.utils.parseUnits(amount,"ether").toString()
}

describe("GHOBorrowVault", function () {
  async function setupAccounts() {
    const [deployer, user1, user2, user3] = await ethers.getSigners()

    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [WETH_FAUCET_ADDRESS],
    });

    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [POOL_ADMIN],
    });

    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [stkAAVE_FAUCET_ADDRESS],
    });

    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [GHO_FAUCET_ADDRESS],
    });

    const wethFaucet = await ethers.getSigner(WETH_FAUCET_ADDRESS);
    const stkAAVEFaucet = await ethers.getSigner(stkAAVE_FAUCET_ADDRESS);
    const ghoFaucet = await ethers.getSigner(GHO_FAUCET_ADDRESS);
    const poolAdmin = await ethers.getSigner(POOL_ADMIN);

    const pool = await IPool__factory.connect(POOL_ADDRESS, ethers.provider)
    const weth = await IERC20__factory.connect(WETH_ADDRESS, ethers.provider)
    const gho = await IERC20__factory.connect(GHO_UNDERLYING_ADDRESS, ethers.provider)
    const aWETH = await IERC20__factory.connect(aWETH_ADDRESS, ethers.provider)
    const stkAAVE = await IERC20__factory.connect(stkAAVE_ADDRESS, ethers.provider)
    const oracle = await IAaveOracle__factory.connect(ORACLE_ADDRESS, ethers.provider)

    const WETHMockAggregator: MockAggregator__factory = await ethers.getContractFactory("MockAggregator");
    const wethMockAggregator:MockAggregator = await WETHMockAggregator.deploy(BIGNUMBER8.mul(4000));
    await oracle.connect(poolAdmin).setAssetSources([WETH_ADDRESS], [wethMockAggregator.address])

    const GhoBorrowVaultFactory: GhoBorrowVault__factory = await ethers.getContractFactory("GhoBorrowVault");
    const ghoBorrowVault:GhoBorrowVault  = <GhoBorrowVault> await upgrades.deployProxy(
      GhoBorrowVaultFactory, 
      [
        toWei("100")
      ]
    )

    return { 
      deployer, 
      user1, 
      user2, 
      user3, 
      pool, 
      weth, 
      wethFaucet, 
      aWETH, 
      poolAdmin, 
      oracle, 
      wethMockAggregator, 
      ghoBorrowVault,
      stkAAVEFaucet,
      stkAAVE,
      gho,
      ghoFaucet,
    }
  }

  it('supply and borrow', async () => {
    const { 
      user1, 
      weth, 
      wethFaucet, 
      ghoBorrowVault,
      stkAAVEFaucet,
      stkAAVE,
      gho,
      ghoFaucet
    } = await loadFixture(setupAccounts);

    const toll = toWei("100")

    let accountInfo = await ghoBorrowVault.accounts(user1.address);
    expect(accountInfo.toll).to.be.equal(0);

    await stkAAVE.connect(stkAAVEFaucet).transfer(user1.address, toll);
    await stkAAVE.connect(user1).approve(ghoBorrowVault.address, toll);
    await ghoBorrowVault.connect(user1).enter();

    accountInfo = await ghoBorrowVault.accounts(user1.address);
    expect(accountInfo.toll).to.be.equal(toll);

    const supplyTotal = toWei("10")

    await weth.connect(wethFaucet).transfer(user1.address, supplyTotal);
    await weth.connect(user1).approve(ghoBorrowVault.address, supplyTotal);
    await ghoBorrowVault.connect(user1).open(supplyTotal)

    expect(await weth.balanceOf(user1.address)).to.be.equal(0);

    const borrowTotal = toWei("20000")
    expect(await gho.balanceOf(user1.address)).to.be.equal(borrowTotal)
    
    await mine(10000);
    await ghoBorrowVault.accrueInterest()
    const balancesWithInterest = await ghoBorrowVault.balanceOf(user1.address);
    expect(balancesWithInterest[0]).to.be.gt(borrowTotal)
    expect(balancesWithInterest[1]).to.be.equal(supplyTotal)
    
    const newGHOBalance = balancesWithInterest[0].add(toWei("1"));
    await gho.connect(ghoFaucet).transfer(user1.address, newGHOBalance);
    await gho.connect(user1).approve(ghoBorrowVault.address, newGHOBalance)
    await ghoBorrowVault.connect(user1).close();

    expect(await weth.balanceOf(user1.address)).to.be.equal(supplyTotal);
  })

  it('liquidation', async () => {
    const { 
      user1, 
      user2,
      weth, 
      wethFaucet, 
      ghoBorrowVault,
      stkAAVEFaucet,
      stkAAVE,
      gho,
      ghoFaucet,
      wethMockAggregator
    } = await loadFixture(setupAccounts);

    const toll = toWei("100")
    await stkAAVE.connect(stkAAVEFaucet).transfer(user1.address, toll);
    await stkAAVE.connect(user1).approve(ghoBorrowVault.address, toll);
    await ghoBorrowVault.connect(user1).enter();

    const supplyTotal = toWei("10")
    await weth.connect(wethFaucet).transfer(user1.address, supplyTotal);
    await weth.connect(user1).approve(ghoBorrowVault.address, supplyTotal);
    await ghoBorrowVault.connect(user1).open(supplyTotal)
    await mine(10000);
    await ghoBorrowVault.accrueInterest()

    await wethMockAggregator.updateAnswer(BIGNUMBER8.mul(3500))
    await expect(ghoBorrowVault.connect(user2).liquidate(user1.address)).to.be.revertedWith("account hasn't reached liquidation threshold");

    const borrowTotal = toWei("20001")
    expect(await weth.balanceOf(user2.address)).to.be.equal(0)
    await wethMockAggregator.updateAnswer(BIGNUMBER8.mul(3000))
    await gho.connect(ghoFaucet).transfer(user2.address, borrowTotal);
    await gho.connect(user2).approve(ghoBorrowVault.address, borrowTotal);
    await ghoBorrowVault.connect(user2).liquidate(user1.address)
    expect(await weth.balanceOf(user2.address)).to.be.gt(0)

  })
});