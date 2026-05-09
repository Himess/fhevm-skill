// Deploy script template for FHEVM contracts using plain ethers + Hardhat.
//
// Usage: npx hardhat run scripts/deploy.ts --network sepolia
//
// This template deliberately AVOIDS `hardhat-deploy` because the package's
// transitive `zksync-web3@0.14.4` dependency crashes against ethers v6 with:
//   TypeError: Cannot read properties of undefined (reading 'JsonRpcSigner')
// (See SKILL.md self-correction table.) The Hardhat config in this skill
// keeps the `hardhat-deploy` import commented out — this script matches that.
//
// If you LATER need named-account / re-run-safe deployments, switch to
// hardhat-ignition (`@nomicfoundation/hardhat-ignition-ethers`) instead of
// hardhat-deploy — Ignition is the official replacement and works with
// ethers v6.
import hre from "hardhat";

async function main() {
  const { ethers } = hre;
  const [deployer] = await ethers.getSigners();
  const network = await ethers.provider.getNetwork();

  console.log(`Deployer:  ${deployer.address}`);
  console.log(`Network:   ${network.name} (chainId ${network.chainId})`);
  console.log(`Balance:   ${ethers.formatEther(await ethers.provider.getBalance(deployer.address))} ETH`);

  // Deploy your contract — adjust args to match your constructor.
  // For an ERC-7984 token from templates/confidential-erc20.sol:
  const factory = await ethers.getContractFactory("ConfidentialToken");
  const contract = await factory.deploy(
    deployer.address,                       // owner
    "MyToken",                              // name
    "MTK",                                  // symbol
    "https://example.com/token.json",       // contractURI
  );
  await contract.waitForDeployment();
  const address = await contract.getAddress();

  console.log(`Deployed:  ${address}`);
  console.log(`Tx hash:   ${contract.deploymentTransaction()?.hash}`);

  // Optional: wait a few blocks before Etherscan verification, then
  //   await hre.run("verify:verify", { address, constructorArguments: [...] });
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
