# Campfire for BEAM

Campfire for BEAM is [Campfire](https://github.com/firoorg/campfire) (a white-label build of
[Stack Wallet](https://github.com/cypherstack/stack_wallet)) converted from Firo to
[BEAM Privacy](https://beam.mw): Campfire's design, philosophy and security, with everything BEAM's
wallets can do. It runs BEAM's own HF6-capable core (`wallet-api` 7.5.14493) as a local child process
bound to 127.0.0.1, so keys never leave the device.

**Status: beta, under active development. Not released yet — do not use it with funds you cannot lose.**

## What works today

- Create and restore BEAM wallets (12-word phrase, checksum-checked), Campfire's password, backups and themes.
- Opens instantly from cache; sync status is honest (never "synced" when behind or on a dead fork).
- Send to an address or a **BEAM name** (BANS); receive with regular, offline, max-privacy and public addresses.
- Transaction history in plain language, cancel, payment proofs.
- **Confidential Assets** as token wallets, with copycat detection and the BEAM desktop wallet's asset icons.
- **DEX**: swap, pools, add/withdraw liquidity, create a pool — every confirmation shows what the signed
  transaction actually does.
- **BEAM names**: register, renew, transfer, sell, buy; money sent to your names is shown on the home screen
  with one-tap Claim.
- **dApps**: store, browser and one approval sheet for every request.
- **Airdrop vouchers**, **token minter** and **burn**.
- **Private node** (desktop): the wallet starts on a public node at once, syncs your own node in the background
  and switches to it seamlessly.

Proven live on BEAM mainnet with small amounts: send/receive, DEX swap, airdrop create and claim.

## Roadmap

**Release 1 — macOS (DMG), Android (APK), Linux**
- [x] BEAM wallet core, honest sync, private node with seamless handover
- [x] Send/receive (all address types), BEAM names, assets, DEX, dApps, airdrops, minter, history
- [ ] Security hardening from the internal review (dApp approvals, asset look-alikes, price sanity)
- [ ] Every feature one or two taps from the wallet (menus)
- [ ] Dashboard: every valuable asset with its fiat value and one-tap send, cached prices
- [ ] Android build (BEAM core packaged for arm64), macOS DMG
- [ ] Public beta

**Release 2**
- [ ] Ethereum: ETH and ERC-20 tokens, with **WBEAM** as a default token
- [ ] BEAM ↔ Ethereum bridge (deposit addresses)
- [ ] iOS
- [ ] Games (Fuddle, MemeClash) and atomic swaps

## Building

```bash
cd scripts && ./build_app.sh -a campfire -p <linux|macos|android> -v <version> -b <build>
```

Flutter 3.47.2. The BEAM core binaries are pinned by SHA-256 and built from tag `beam-7.5.14493`
(`scripts/beam/core/`).

---

[![codecov](https://codecov.io/gh/cypherstack/stack_wallet/branch/main/graph/badge.svg?token=PM1N56UTEW)](https://codecov.io/gh/cypherstack/stack_wallet)

# Stack Wallet
Stack Wallet is a fully open source cryptocurrency wallet. With an easy to use user interface and quick and speedy transactions, this wallet is ideal for anyone no matter how much they know about the cryptocurrency space. The app is actively maintained to provide new user friendly features.

<a href="https://play.google.com/store/apps/details?id=com.cypherstack.stackwallet">
<img width="250px" src="https://play.google.com/intl/en_us/badges/static/images/badges/en_badge_web_generic.png"></img>
</a>

## Feature List

Highlights include:
- 23 Different cryptocurrencies:
    - [Bitcoin](https://bitcoin.org/en/)
    - Bitcoin Frost
    - [Bitcoin Cash](https://bch.info/en/)
    - [Banano](https://banano.cc/)
    - [Cardano](https://cardano.org/)
    - [Dash](https://www.dash.org/)
    - [Dogecoin](https://dogecoin.com/)
    - [Epic Cash](https://linktr.ee/epiccash)
    - [MimbleWimbleCoin](https://mwc.mw)
    - [Ethereum](https://ethereum.org/en/)
    - [Ecash](https://e.cash/)
    - [Fact0rn](https://www.fact0rn.io/)
    - [Firo](https://firo.org/)
    - [Litecoin](https://litecoin.org/)
    - [Monero](https://www.getmonero.org/)
    - [Nano](https://nano.org/)
    - [Namecoin](https://www.namecoin.org/)
    - [Particl](https://particl.io/)
    - [Peercoin](https://www.peercoin.net/)
    - [Salvium](https://salvium.io/)
    - [Solana](https://solana.com/)
    - [Stellar](https://stellar.org/)
    - [Tezos](https://tezos.com/)
    - [Wownero](https://wownero.org/)
    - [Xelis](https://xelis.org/)
- All private keys and seeds stay on device and are never shared.
- Easy backup and restore feature to save all the information that's important to you.
- Trading cryptocurrencies through our partners.
- Custom address book
- Favorite wallets with fast syncing
- Custom Nodes.
- Open source software.
- No ads.

## Building

You can look at the [build instructions](docs/building.md) for more details.
