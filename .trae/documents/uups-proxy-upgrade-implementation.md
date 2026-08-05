# UUPS Proxy Upgrade Implementation Plan

## Summary
Implement UUPS proxy upgrade pattern for ERC721 NFT contract, fixing the existing V1 and V2 contracts, creating deployment scripts and tests.

## Current State Analysis
- **ERC721_Upgrade_V1.sol**: Missing proper imports and inheritance for upgradeable contracts
- **ERC721_Upgrade_V2.sol**: Incorrect initialization pattern (should use `reinitializer(2)`)
- **Dependencies**: Missing `openzeppelin-contracts-upgradeable` library
- **Tests/Scripts**: No deployment or test files exist

## Implementation Steps

### 1. Install OpenZeppelin Upgradeable Contracts
```bash
forge install OpenZeppelin/openzeppelin-contracts-upgradeable
```

Update `remappings.txt` to include:
```
@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/
```

### 2. Fix ERC721_Upgrade_V1.sol
- Import from upgradeable contracts:
  - `ERC721Upgradeable`
  - `OwnableUpgradeable`
  - `UUPSUpgradeable`
  - `Initializable`
- Inherit in correct order: `Initializable, ERC721Upgradeable, OwnableUpgradeable, UUPSUpgradeable`
- Use `__ERC721_init()` and `__Ownable_init()` in initialize function
- Keep `_authorizeUpgrade()` with `onlyOwner` modifier

### 3. Fix ERC721_Upgrade_V2.sol
- Inherit from `ERC721_Upgrade_V1`
- Use `reinitializer(2)` modifier for `initializeV2()` function
- Add new state variables and functions for V2 features

### 4. Create Deployment Script
Create `script/DeployUpgradeableNFT.s.sol`:
- Deploy V1 implementation
- Deploy ERC1967Proxy with V1 implementation
- Initialize proxy with name and symbol
- Deploy V2 implementation
- Upgrade proxy to V2 using `upgradeToAndCall()`
- Call `initializeV2()` through proxy

### 5. Create Test File
Create `test/UpgradeableNFT.t.sol`:
- Test initial deployment and initialization
- Test V1 functionality (mint, ownership)
- Test upgrade to V2
- Test V2 functionality
- Verify state preservation after upgrade
- Test authorization (only owner can upgrade)

## Key Files to Modify/Create
1. `/Users/mac/learn/web3/2026/07/FoundryPrac/remappings.txt` - Add upgradeable mapping
2. `/Users/mac/learn/web3/2026/07/FoundryPrac/src/upgrade-nft/ERC721_Upgrade_V1.sol` - Fix imports and inheritance
3. `/Users/mac/learn/web3/2026/07/FoundryPrac/src/upgrade-nft/ERC721_Upgrade_V2.sol` - Fix initialization pattern
4. `/Users/mac/learn/web3/2026/07/FoundryPrac/script/DeployUpgradeableNFT.s.sol` - Create deployment script
5. `/Users/mac/learn/web3/2026/07/FoundryPrac/test/UpgradeableNFT.t.sol` - Create test file

## Verification
1. Run `forge build` to ensure compilation succeeds
2. Run `forge test` to verify all tests pass
3. Test deployment script with `forge script script/DeployUpgradeableNFT.s.sol --fork-url local`
