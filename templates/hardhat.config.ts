// IMPORTANT: Requires Hardhat 2 (^2.22.0). Hardhat 3 is NOT compatible with @fhevm/hardhat-plugin.
// Install: npm install hardhat@^2.22.0
//
// NODE COMPATIBILITY: Hardhat 2 officially supports Node 18 / 20 / 22.
// Node 24+ prints `WARNING: You are currently using Node.js vX.X.X, which is
// not supported` but generally works. Pin via .nvmrc / engines if you can.
import { HardhatUserConfig } from "hardhat/config";
import "@fhevm/hardhat-plugin";
import "@nomicfoundation/hardhat-chai-matchers";
import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-verify";
import "@typechain/hardhat";
// NOTE: hardhat-deploy is INTENTIONALLY NOT imported by default.
// hardhat-deploy@0.11.45 transitively pulls zksync-web3@0.14.4, which crashes
// at module-load time on ethers v6 with:
//   TypeError: Cannot read properties of undefined (reading 'JsonRpcSigner')
// If you need named-account deployment scripts, install matching versions
// (e.g. hardhat-deploy >=0.12 once available against Hardhat 2 + ethers 6),
// then uncomment the import below and the `namedAccounts` block at the bottom.
// import "hardhat-deploy";

// Use plain `process.env` for both options below — env vars + a default.
// (We previously used Hardhat's `vars.get(KEY, default)`, but in Hardhat
// 2.28.x the `default` only kicks in *after* `npx hardhat vars set KEY`
// has been run at least once on the machine. On a fresh install it throws
// `TypeError: Cannot read properties of undefined (reading 'KEY')` despite
// the default. Two stress-test agents hit this on first compile. Plain
// `process.env.KEY ?? default` is unambiguously fallback-safe.)
//
// Option A: shell env vars
//   export MNEMONIC="..."
//   export INFURA_API_KEY="..."
// Option B: .env file (add to .gitignore!) + `dotenv/config` import at the top:
//   import "dotenv/config";
//   DEPLOYER_PRIVATE_KEY=0x...
//   INFURA_API_KEY=...
const MNEMONIC = process.env.MNEMONIC ?? "test test test test test test test test test test test junk";
const INFURA_API_KEY = process.env.INFURA_API_KEY ?? "";
const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY ?? "";

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
      metadata: {
        bytecodeHash: "none", // Deterministic builds for Etherscan verification
      },
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
  // namedAccounts requires `hardhat-deploy` import above. Uncomment both together.
  // namedAccounts: {
  //   deployer: 0,
  //   alice: 1,
  //   bob: 2,
  // },
  // Gas reporting for FHE operation benchmarking
  gasReporter: {
    enabled: process.env.REPORT_GAS === "true",
    currency: "USD",
  },
};

export default config;
