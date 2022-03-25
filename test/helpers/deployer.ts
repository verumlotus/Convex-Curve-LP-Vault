import { ethers } from "hardhat";
import { BigNumberish, Signer } from "ethers";
import "module-alias/register";
import { IERC20__factory } from "typechain/factories/IERC20__factory";
import { IERC20 } from "typechain/IERC20";
import {
  ConvexAssetProxy,
  ConstructorParamsStruct,
} from "typechain/ConvexAssetProxy";
import { IConvexBooster } from "typechain/IConvexBooster";
import { IConvexBaseRewardPool } from "typechain/IConvexBaseRewardPool";
import { ISwapRouter } from "typechain/ISwapRouter";
import { I3CurvePoolDepositZap } from "typechain/I3CurvePoolDepositZap";
import { IConvexBooster__factory } from "typechain/factories/IConvexBooster__factory";
import { IConvexBaseRewardPool__factory } from "typechain/factories/IConvexBaseRewardPool__factory";
import { I3CurvePoolDepositZap__factory } from "./../../typechain/factories/I3CurvePoolDepositZap__factory";
import { ConvexAssetProxy__factory } from "typechain/factories/ConvexAssetProxy__factory";
import { ISwapRouter__factory } from "typechain/factories/ISwapRouter__factory";

export interface ConvexFixtureInterface {
  signer: Signer;
  position: ConvexAssetProxy;
  booster: IConvexBooster;
  rewardsContract: IConvexBaseRewardPool;
  curveZap: I3CurvePoolDepositZap;
  curveMetaPool: string;
  convexDepositToken: IERC20;
  lpToken: IERC20;
  router: ISwapRouter;
  usdc: IERC20;
  crv: IERC20;
  cvx: IERC20;
}

const deployConvexAssetProxy = async (
  signer: Signer,
  curveZap: string,
  curveMetaPool: string,
  booster: string,
  rewardsContract: string,
  convexDepositToken: string,
  router: string,
  pid: BigNumberish,
  keeperFee: BigNumberish,
  crvSwapPath: string,
  cvxSwapPath: string,
  token: string,
  name: string,
  symbol: string,
  governance: string,
  pauser: string
) => {
  const convexDeployer = new ConvexAssetProxy__factory(signer);
  const constructorParams: ConstructorParamsStruct = {
    curveZap: curveZap,
    curveMetaPool: curveMetaPool,
    booster: booster,
    rewardsContract: rewardsContract,
    convexDepositToken: convexDepositToken,
    router: router,
    pid: pid,
    keeperFee: keeperFee,
  };
  return await convexDeployer.deploy(
    constructorParams,
    crvSwapPath,
    cvxSwapPath,
    token,
    name,
    symbol,
    governance,
    pauser
  );
};

export async function loadConvexFixture(
  signer: Signer
): Promise<ConvexFixtureInterface> {
  // Some addresses specific to LUSD3CRV pool
  const wethAddress = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
  const owner = signer;
  const usdcAddress = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48";
  const crvAddress = "0xD533a949740bb3306d119CC777fa900bA034cd52";
  const cvxAddress = "0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B";
  const boosterAddress = "0xF403C135812408BFbE8713b5A23a04b3D48AAE31";
  const rewardsContractAddress = "0x2ad92A7aE036a038ff02B96c88de868ddf3f8190";
  const pool3CrvDepositZapAddress =
    "0xA79828DF1850E8a3A3064576f380D90aECDD3359";
  // Metapool for LUSD3CRV, also the LP token address
  const curveMetaPool = "0xEd279fDD11cA84bEef15AF5D39BB4d4bEE23F0cA";
  const cvxLusd3CRV = "0xFB9B2f06FDb404Fd3E2278E9A9edc8f252F273d0";
  // Uniswap V3 router address
  const routerAddress = "0xE592427A0AEce92De3Edee1F18E0157C05861564";
  // Pool ID for LUSD-3CRV pool
  const pid = 33;
  // Keeper fee is 5%
  const keeperFee = 50;
  // multi-hops are [TokenA, fee, TokenB, fee, TokenC, ... TokenOut]
  // Jump from CRV to WETH to USDC
  // Note: 10000 = 1% pool fee
  const crvSwapPath = ethers.utils.solidityPack(
    ["address", "uint24", "address", "uint24", "address"],
    [crvAddress, 10000, wethAddress, 500, usdcAddress]
  );
  const cvxSwapPath = ethers.utils.solidityPack(
    ["address", "uint24", "address", "uint24", "address"],
    [cvxAddress, 10000, wethAddress, 500, usdcAddress]
  );

  const usdc = IERC20__factory.connect(usdcAddress, owner);
  const crv = IERC20__factory.connect(crvAddress, owner);
  const cvx = IERC20__factory.connect(cvxAddress, owner);
  const booster = IConvexBooster__factory.connect(boosterAddress, owner);
  const rewardsContract = IConvexBaseRewardPool__factory.connect(
    rewardsContractAddress,
    owner
  );
  const curveZap = I3CurvePoolDepositZap__factory.connect(
    pool3CrvDepositZapAddress,
    owner
  );
  const convexDepositToken = IERC20__factory.connect(cvxLusd3CRV, owner);
  const lpToken = IERC20__factory.connect(curveMetaPool, owner);
  const router = ISwapRouter__factory.connect(routerAddress, owner);

  const ownerAddress = await signer.getAddress();

  const position: ConvexAssetProxy = await deployConvexAssetProxy(
    owner,
    pool3CrvDepositZapAddress,
    curveMetaPool,
    boosterAddress,
    rewardsContractAddress,
    cvxLusd3CRV,
    routerAddress,
    pid,
    keeperFee,
    crvSwapPath,
    cvxSwapPath,
    curveMetaPool,
    "proxyLusd3CRV",
    "epLusd3Crv",
    ownerAddress,
    ownerAddress
  );

  return {
    signer,
    position,
    booster,
    rewardsContract,
    curveZap,
    curveMetaPool,
    convexDepositToken,
    lpToken,
    router,
    usdc,
    crv,
    cvx,
  };
}
