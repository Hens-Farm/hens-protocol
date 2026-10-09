# Hens Protocol

<p align="center"><img src="assets/hegg-token.png" width="160" alt="Hens"></p>

Hens is an onchain NFT protocol on Robinhood Chain. Hens accrue HEGG from a fixed reserve. HEGG burned through protocol participation becomes permanent Hen weight, and that weight determines participation in the daily GLD distribution.

This repository is the public source reference for the deployed Hens protocol. It contains Solidity source files, public ABIs and the current Robinhood Chain deployment addresses. It intentionally excludes private infrastructure, signing material, operator configuration and deployment secrets.

## Official links

* Website: [hens.farm](https://hens.farm)
* Documentation: [hens.farm/docs](https://hens.farm/docs)
* X: [x.com/hensdotfarm](https://x.com/hensdotfarm)
* Discord: [discord.gg/Ukjy9RtfGt](https://discord.gg/Ukjy9RtfGt)
* Medium: [medium.com/@hensfarm](https://medium.com/@hensfarm)

## Network

* Network: Robinhood Chain Mainnet
* Chain ID: `4663`
* Native gas token: ETH
* Explorer: [Robinhood Chain Etherscan](https://robin.etherscan.io)

## Core contracts

| Contract | Address |
| --- | --- |
| Hens NFT proxy | [`0x00466c0053fa70c309e778b49293f5a1c3da1cde`](https://robin.etherscan.io/address/0x00466c0053fa70c309e778b49293f5a1c3da1cde#code) |
| HEGG token | [`0x7a586d4f3b2b659e3b06e555726107e4cbbceab2`](https://robin.etherscan.io/address/0x7a586d4f3b2b659e3b06e555726107e4cbbceab2#code) |
| HEGG tax hook | [`0xab1463582af21d843e2425fc0e5b5cee190a40cc`](https://robin.etherscan.io/address/0xab1463582af21d843e2425fc0e5b5cee190a40cc#code) |
| Emissions proxy | [`0x70a603838af63b6f782bc307146c22c0710c797e`](https://robin.etherscan.io/address/0x70a603838af63b6f782bc307146c22c0710c797e#code) |
| Claims proxy | [`0xa7a3a913501ceee6ddcefcb597ce3469ef6a0542`](https://robin.etherscan.io/address/0xa7a3a913501ceee6ddcefcb597ce3469ef6a0542#code) |
| Daily GLD vault proxy | [`0xc2bc18addf0404321b9d226759a753aef58c87d5`](https://robin.etherscan.io/address/0xc2bc18addf0404321b9d226759a753aef58c87d5#code) |
| Marketplace | [`0x901d9ebfc506ccfd529be32a3c1a577d54ca904e`](https://robin.etherscan.io/address/0x901d9ebfc506ccfd529be32a3c1a577d54ca904e#code) |
| Public mint bond | [`0x8774c09f32755c3147137439467b1e66c9fef607`](https://robin.etherscan.io/address/0x8774c09f32755c3147137439467b1e66c9fef607#code) |

The complete public address manifest is in [`deployments/robinhood-mainnet.json`](deployments/robinhood-mainnet.json).

## Repository layout

* `src/` contains the protocol Solidity sources.
* `abi/` contains compact ABI files for the primary public contracts.
* `deployments/` contains public network and contract addresses.

## Authenticity

Contract names and token symbols can be copied. Always verify addresses against this repository, the official website and the explorer before interacting.

## Security

Please do not disclose a suspected vulnerability publicly. Follow [SECURITY.md](SECURITY.md) and contact `bok@hens.farm`.

## Source availability

The source is published for transparency and verification. No licence is granted beyond rights required by applicable law unless a specific file states otherwise.
