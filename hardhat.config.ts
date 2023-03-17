import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@openzeppelin/hardhat-upgrades";
import { config as dotenvConfig } from "dotenv";
import { resolve } from "path";

dotenvConfig({ path: resolve(__dirname, "./.env") });

const rpcURL: string | undefined = process.env.RPC_URL;
if (!rpcURL) {
  throw new Error("Please set your RPC_URL in a .env file");
}

const config: HardhatUserConfig = {
  solidity: "0.8.18",
  networks: {
    hardhat: {
      loggingEnabled: false,
      forking: {
        url: rpcURL,
        blockNumber: 8664999,
      },
      accounts: {
        accountsBalance: "1000000000000000000",
      },
    },
  }
};

export default config;
