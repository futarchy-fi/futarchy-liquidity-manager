#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { JsonRpcProvider, Wallet, getAddress, isHexString } from "ethers";

const required = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`missing ${name}`);
  return value;
};

const provider = new JsonRpcProvider(required("RPC_URL"));
const signer = new Wallet(required("PRIVATE_KEY"), provider);
const expectedSigner = getAddress(required("EXPECTED_SIGNER"));
if (signer.address !== expectedSigner) throw new Error("unexpected signer");

const network = await provider.getNetwork();
const expectedChainId = BigInt(required("EXPECTED_CHAIN_ID"));
if (network.chainId !== expectedChainId) throw new Error("unexpected chain");

const data = (process.env.TX_DATA || readFileSync(required("TX_DATA_FILE"), "utf8")).trim();
if (!isHexString(data) || data === "0x") throw new Error("invalid transaction data");

const tx = { data, value: BigInt(process.env.TX_VALUE || "0") };
if (process.env.TX_TO) tx.to = getAddress(process.env.TX_TO);

await provider.call({ ...tx, from: signer.address });
const estimate = await provider.estimateGas({ ...tx, from: signer.address });
tx.gasLimit = (estimate * 120n + 99n) / 100n;

const response = await signer.sendTransaction(tx);
console.log(JSON.stringify({ txHash: response.hash }));

const confirmations = Number(process.env.CONFIRMATIONS || "2");
const receipt = await response.wait(confirmations);
if (!receipt || receipt.status !== 1) throw new Error("transaction failed");

if (!tx.to) {
  if (!receipt.contractAddress) throw new Error("missing contract address");
  const code = await provider.getCode(receipt.contractAddress);
  if (code === "0x") throw new Error("deployed contract has no code");
}

console.log(
  JSON.stringify({
    blockNumber: receipt.blockNumber,
    contractAddress: receipt.contractAddress,
    gasUsed: receipt.gasUsed.toString(),
    status: receipt.status,
  }),
);
