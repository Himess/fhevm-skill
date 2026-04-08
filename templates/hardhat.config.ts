// IMPORTANT: Requires Hardhat 2 (^2.22.0). Hardhat 3 is NOT compatible with @fhevm/hardhat-plugin.
// Install: npm install hardhat@^2.22.0
import { HardhatUserConfig, vars } from "hardhat/config";
import "@fhevm/hardhat-plugin";
import "@nomicfoundation/hardhat-chai-matchers";
import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-verify";
import "@typechain/hardhat";
import "hardhat-deploy";

// Option A: Use hardhat vars (recommended):
//   npx hardhat vars set MNEMONIC
//   npx hardhat vars set INFURA_API_KEY
// Option B: Use .env file with dotenv (add to .gitignore!):
//   DEPLOYER_PRIVATE_KEY=0x...
//   INFURA_API_KEY=...
const MNEMONIC = vars.get("MNEMONIC", "test test test test test test test test test test test junk");
const INFURA_API_KEY = vars.get("INFURA_API_KEY", "");
const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY || "";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.27",
    settings: {
      optimizer: {
        enabled: true,
        runs: 800,
      },
      viaIR: true,          // Required for complex FHE contracts (avoids stack-too-deep)
      evmVersion: "cancun", // REQUIRED: EIP-1153 transient storage for FHE.allowTransient()
    },
  },
  networks: {
    hardhat: {
      chainId: 31337,
      allowBlocksWithSameTimestamp: true, // Prevents timestamp collision in time-based tests
    },
    sepolia: {
      url: INFURA_API_KEY
        ? `https://sepolia.infura.io/v3/${INFURA_API_KEY}`
        : "https://ethereum-sepolia-rpc.publicnode.com", // Public RPC, no key needed
      accounts: DEPLOYER_PRIVATE_KEY
        ? [DEPLOYER_PRIVATE_KEY]  // Single private key (most common for devs)
        : { mnemonic: MNEMONIC, count: 10 },
      chainId: 11155111,
    },
  },
  namedAccounts: {
    deployer: 0,
    alice: 1,
    bob: 2,
  },
  // Gas reporting for FHE operation benchmarking
  gasReporter: {
    enabled: process.env.REPORT_GAS === "true",
    currency: "USD",
  },
};

export default config;
