// Deploy script template for FHEVM contracts using hardhat-deploy.
// Usage: npx hardhat deploy --network sepolia
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();

  console.log("Deploying with account:", deployer);

  // Deploy your contract — adjust args to match your constructor
  const result = await deploy("MyContract", {
    from: deployer,
    args: [
      // constructor args here, e.g.:
      // deployer,                    // owner address
      // "MyToken",                   // name
      // "MTK",                       // symbol
      // "https://example.com/token"  // contractURI (for ERC-7984)
    ],
    log: true,
  });

  console.log("Deployed at:", result.address);
};

export default func;
func.tags = ["MyContract"];
