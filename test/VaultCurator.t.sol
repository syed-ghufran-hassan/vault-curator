// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ============================================================================
//                                  IMPORTS
// ============================================================================

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

import {CuratedVault} from "../contracts/CuratedVault.sol";
import {CuratedLiquidityHook} from "../contracts/CuratedLiquidityHook.sol";
import {StrategyRegistry} from "../contracts/StrategyRegistry.sol";
import {AllowlistChecker} from "../contracts/AllowlistChecker.sol";
import {IAllowlistChecker} from "../contracts/interfaces/IAllowlistChecker.sol";

// ============================================================================
//                                   MOCKS
// ============================================================================

/// @notice Mock USDC with 6 decimals.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Minimal oracle for tests.
contract MockOracle {
    uint256 public price;

    constructor(uint256 _initialPrice) {
        price = _initialPrice;
    }

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function getPrice() external view returns (uint256) {
        return price;
    }
}

// ============================================================================
//                              HOOK DEPLOYER
// ============================================================================

/// @notice Library to mine a hook address and deploy CuratedLiquidityHook via CREATE2.
library HookDeployer {
    function deploy(
        Vm vm,
        IPoolManager poolManager,
        address owner,
        address oracle,
        uint24 baseFee,
        uint24 maxFee
    ) internal returns (CuratedLiquidityHook hook) {
        uint160 requiredFlags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG
        );

        bytes memory creationCode = abi.encodePacked(
            type(CuratedLiquidityHook).creationCode,
            abi.encode(poolManager, owner, oracle, baseFee, maxFee)
        );

        address deployer = address(uint160(uint256(keccak256("hook-deployer"))));
        bytes32 codeHash = keccak256(creationCode);

        bytes32 salt;
        address predicted;
        bool found;
        for (uint256 i = 0; i < 500_000; i++) {
            bytes32 s = bytes32(i);
            address p = address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(bytes1(0xff), deployer, s, codeHash)
                        )
                    )
                )
            );
            if ((uint160(p) & 0x3FFF) == requiredFlags) {
                salt = s;
                predicted = p;
                found = true;
                break;
            }
        }
        require(found, "HookDeployer: no salt found");

        vm.deal(deployer, 1 ether);

        vm.prank(deployer);
        address deployed;
        assembly {
            deployed := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        require(deployed == predicted, "HookDeployer: address mismatch");

        hook = CuratedLiquidityHook(deployed);
    }
}

// ============================================================================
//                            CURATED VAULT TESTS
// ============================================================================

contract CuratedVaultTest is Test {
    MockUSDC usdc;
    CuratedVault vault;

    address owner = address(0xA11CE);
    address manager = address(0xB0B);
    address alice = address(0xA1);
    address bob = address(0xB1);

    uint256 constant MGMT_FEE_BPS = 100;
    uint256 constant PERF_FEE_BPS = 1500;

    function setUp() public {
        usdc = new MockUSDC();

        vm.prank(owner);
        vault = new CuratedVault(
            usdc,
            "Alpha LP Vault",
            "aLP",
            owner,
            manager,
            MGMT_FEE_BPS,
            PERF_FEE_BPS
        );
    }

    // ---------- Construction ----------

    function test_InitialState() public view {
        assertEq(vault.name(), "Alpha LP Vault");
        assertEq(vault.symbol(), "aLP");
        assertEq(vault.mgmtFeeBps(), MGMT_FEE_BPS);
        assertEq(vault.perfFeeBps(), PERF_FEE_BPS);
        assertEq(vault.feeRecipient(), manager);
        assertEq(vault.highWaterMark(), 1e18);
        assertEq(vault.depositCap(), 0);
        assertFalse(vault.depositsPaused());
    }

    function test_ConstructorRejectsHighMgmtFee() public {
        vm.expectRevert("mgmt fee too high");
        new CuratedVault(usdc, "X", "X", owner, manager, 501, 0);
    }

    function test_ConstructorRejectsHighPerfFee() public {
        vm.expectRevert("perf fee too high");
        new CuratedVault(usdc, "X", "X", owner, manager, 0, 2001);
    }

    function test_ConstructorRejectsZeroFeeRecipient() public {
        vm.expectRevert("zero fee recipient");
        new CuratedVault(usdc, "X", "X", owner, address(0), 0, 0);
    }

    // ---------- Deposit / Withdraw ----------

    function test_DepositMintsShares() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        uint256 shares = vault.deposit(1000e6, alice);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(vault.totalAssets(), 1000e6);
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_WithdrawReturnsAssets() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);

        vm.prank(alice);
        uint256 assets = vault.withdraw(500e6, alice, alice);

        assertApproxEqAbs(assets, 500e6, 2);
        assertApproxEqAbs(vault.totalAssets(), 500e6, 2);
    }

    function test_RedeemReturnsAssets() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        uint256 shares = vault.deposit(1000e6, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);

        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        assertApproxEqAbs(assets, 1000e6, 2);
    }

    function test_MultipleDepositors() public {
        usdc.mint(alice, 1000e6);
        usdc.mint(bob, 2000e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(vault), 2000e6);
        vault.deposit(2000e6, bob);
        vm.stopPrank();

        assertEq(vault.totalAssets(), 3000e6);
        assertApproxEqRel(
            vault.balanceOf(bob),
            vault.balanceOf(alice) * 2,
            1e15
        );
    }

    // ---------- Performance Fee ----------

    function test_PerformanceFeeAccruesOnProfit() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, alice);
        vm.stopPrank();

        usdc.mint(address(vault), 500e6);

        vm.warp(block.timestamp + 1 days);
        vault.harvest();

        assertGt(vault.balanceOf(manager), 0, "manager should earn shares");
        assertGt(vault.highWaterMark(), 1e18, "HWM should rise");
    }

    function test_NoPerformanceFeeBelowHwm() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        vault.harvest();

        assertEq(vault.highWaterMark(), 1e18, "HWM unchanged");
    }

    function test_HwmMonotonicAfterDrawdown() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, alice);
        vm.stopPrank();

        usdc.mint(address(vault), 500e6);
        vm.warp(block.timestamp + 1 days);
        vault.harvest();
        uint256 hwmAfterProfit = vault.highWaterMark();

        vm.prank(address(vault));
        usdc.transfer(address(0xdead), 200e6);

        vm.warp(block.timestamp + 1 days);
        vault.harvest();

        assertEq(vault.highWaterMark(), hwmAfterProfit, "HWM never decreases");
    }

    function test_PerformanceFeeAmount() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, alice);
        vm.stopPrank();

        usdc.mint(address(vault), 100e6);
        vm.warp(block.timestamp + 1 seconds);

        uint256 managerBefore = vault.balanceOf(manager);
        vault.harvest();

        uint256 managerShares = vault.balanceOf(manager) - managerBefore;
        uint256 expectedShares = vault.convertToShares(15e6);

        assertApproxEqRel(managerShares, expectedShares, 2e17);
    }

    // ---------- Management Fee ----------

    function test_ManagementFeeAccruesOverTime() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, alice);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        vault.harvest();

        assertGt(vault.balanceOf(manager), 0);
    }

    // ---------- Deposit Cap / Pause ----------

    function test_DepositCapEnforced() public {
        vm.prank(owner);
        vault.setDepositCap(500e6);

        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert();
        vault.deposit(1000e6, alice);
        vm.stopPrank();
    }

    function test_DepositBelowCap() public {
        vm.prank(owner);
        vault.setDepositCap(2000e6);

        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, alice);
        vm.stopPrank();

        assertEq(vault.totalAssets(), 1000e6);
    }

    function test_PauseBlocksDeposits() public {
        vm.prank(owner);
        vault.setDepositsPaused(true);

        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert();
        vault.deposit(1000e6, alice);
        vm.stopPrank();
    }

    function test_PauseDoesNotBlockWithdrawals() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1000e6, alice);
        vm.stopPrank();

        vm.prank(owner);
        vault.setDepositsPaused(true);

        vm.prank(alice);
        vault.withdraw(500e6, alice, alice);
    }

    // ---------- Fee Admin ----------

    function test_FeeChangeRequiresCooldown() public {
        vm.prank(owner);
        vm.expectRevert("cooldown");
        vault.setMgmtFee(200);
    }

    function test_FeeChangeTooLargeReverts() public {
        vm.warp(block.timestamp + 8 days);
        vm.prank(owner);
        vm.expectRevert("increase too large");
        vault.setMgmtFee(500);
    }

    function test_FeeAboveMaxReverts() public {
        vm.prank(owner);
        vm.expectRevert("above max");
        vault.setPerfFee(3000);
    }

    function test_SetFeeRecipient() public {
        vm.prank(owner);
        vault.setFeeRecipient(bob);
        assertEq(vault.feeRecipient(), bob);
    }

    function test_SetFeeRecipientRejectsZero() public {
        vm.prank(owner);
        vm.expectRevert("zero address");
        vault.setFeeRecipient(address(0));
    }

    // ---------- Access Control ----------

    function test_SetMgmtFeeOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setMgmtFee(200);
    }

    function test_SetDepositCapOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setDepositCap(1000e6);
    }

    // ---------- Fuzz ----------

    function testFuzz_DepositWithdraw(uint96 amount) public {
        amount = uint96(bound(amount, 1e6, 1_000_000e6));

        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);

        vm.warp(block.timestamp + 1 hours);
        uint256 assetsBack = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertApproxEqAbs(assetsBack, amount, 2);
    }
}

// ============================================================================
//                       CURATED LIQUIDITY HOOK TESTS
// ============================================================================

contract CuratedLiquidityHookTest is Test {
    CuratedLiquidityHook hook;
    AllowlistChecker checker;
    MockOracle oracle;

    address owner = address(0xA11CE);
    address alice = address(0xA1);
    address poolManager = address(0xdead);

    uint24 constant BASE_FEE = 500;
    uint24 constant MAX_FEE = 3000;

    function setUp() public {
        checker = new AllowlistChecker(owner);
        oracle = new MockOracle(1e18);

        hook = HookDeployer.deploy(
            vm,
            IPoolManager(poolManager),
            owner,
            address(oracle),
            BASE_FEE,
            MAX_FEE
        );
    }

    // ---------- Deployment ----------

    function test_HookAddressHasCorrectFlags() public view {
        uint160 expected = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG
        );
        assertEq(uint160(address(hook)) & 0x3FFF, expected);
    }

    function test_InitialState() public view {
        assertEq(hook.baseFee(), BASE_FEE);
        assertEq(hook.maxFee(), MAX_FEE);
        assertEq(hook.oracle(), address(oracle));
        assertEq(hook.maxDeviationBps(), 200);
        assertEq(hook.rebalanceCooldown(), 1 hours);
        assertFalse(hook.gatingEnabled());
    }

    function test_GetHookPermissionsReturnsCorrectFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeAddLiquidity);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertFalse(p.beforeInitialize);
        assertFalse(p.afterInitialize);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
    }

    // ---------- Admin Setters ----------

    function test_SetGatingEnabled() public {
        vm.prank(owner);
        hook.setGatingEnabled(true);
        assertTrue(hook.gatingEnabled());
    }

    function test_SetGatingDisabled() public {
        vm.prank(owner);
        hook.setGatingEnabled(true);

        vm.prank(owner);
        hook.setGatingEnabled(false);
        assertFalse(hook.gatingEnabled());
    }

    function test_SetAllowlistChecker() public {
        vm.prank(owner);
        hook.setAllowlistChecker(address(checker));
        assertEq(address(hook.allowlistChecker()), address(checker));
    }

    function test_SetAllowlistCheckerOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        hook.setAllowlistChecker(address(checker));
    }

    function test_SetDynamicFee() public {
        vm.prank(owner);
        hook.setDynamicFee(1000, 5000);
        assertEq(hook.baseFee(), 1000);
        assertEq(hook.maxFee(), 5000);
    }

    function test_SetDynamicFeeInvalidRangeReverts() public {
        vm.prank(owner);
        vm.expectRevert("base > max");
        hook.setDynamicFee(5000, 1000);
    }

    function test_SetMaxDeviation() public {
        vm.prank(owner);
        hook.setMaxDeviation(500);
        assertEq(hook.maxDeviationBps(), 500);
    }

    function test_SetRebalanceCooldown() public {
        vm.prank(owner);
        hook.setRebalanceCooldown(2 hours);
        assertEq(hook.rebalanceCooldown(), 2 hours);
    }

    function test_SetMaxDeviationOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        hook.setMaxDeviation(1000);
    }

    // ---------- Rebalance ----------

    function test_RebalanceOnlyOwner() public {
        PoolKey memory key = _dummyPoolKey();

        vm.prank(alice);
        vm.expectRevert();
        hook.rebalance(key);
    }

    function test_RebalanceRevertsOnLowDeviation() public {
        PoolKey memory key = _dummyPoolKey();

        vm.prank(owner);
        vm.expectRevert("CuratedLiquidityHook: deviation too low");
        hook.rebalance(key);
    }

    // ---------- Integration with Allowlist ----------

    function test_AllowlistCheckerIntegration() public {
        vm.prank(owner);
        hook.setAllowlistChecker(address(checker));
        assertEq(address(hook.allowlistChecker()), address(checker));
    }

    // ---------- Helpers ----------

   function _dummyPoolKey() internal view returns (PoolKey memory) {
    return PoolKey({
        currency0: Currency.wrap(address(0)),
        currency1: Currency.wrap(address(0)),
        fee: 0,
        tickSpacing: 0,
        hooks: IHooks(address(hook))
    });
}
}

// ============================================================================
//                           ALLOWLIST CHECKER TESTS
// ============================================================================

contract AllowlistCheckerTest is Test {
    AllowlistChecker checker;

    address owner = address(0xA11CE);
    address alice = address(0xA1);
    address bob = address(0xB1);

    function setUp() public {
        checker = new AllowlistChecker(owner);
    }

    // ---------- Allowlist Mode ----------

    function test_DefaultModeIsAllowlist() public view {
        assertEq(uint256(checker.mode()), uint256(AllowlistChecker.GatingMode.ALLOWLIST));
    }

    function test_DefaultNotAllowed() public view {
        assertFalse(checker.checkAllowlist(alice, address(0)));
    }

    function test_SetAllowlist() public {
        vm.prank(owner);
        checker.setAllowlist(alice, true);
        assertTrue(checker.checkAllowlist(alice, address(0)));
    }

    function test_RemoveFromAllowlist() public {
        vm.prank(owner);
        checker.setAllowlist(alice, true);

        vm.prank(owner);
        checker.setAllowlist(alice, false);

        assertFalse(checker.checkAllowlist(alice, address(0)));
    }

    function test_BatchSetAllowlist() public {
        address[] memory accounts = new address[](3);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = address(0xC1);

        vm.prank(owner);
        checker.batchSetAllowlist(accounts, true);

        assertTrue(checker.checkAllowlist(alice, address(0)));
        assertTrue(checker.checkAllowlist(bob, address(0)));
        assertTrue(checker.checkAllowlist(address(0xC1), address(0)));
    }

    // ---------- Gating Modes ----------

    function test_SetGatingMode() public {
        vm.prank(owner);
        checker.setGatingMode(AllowlistChecker.GatingMode.NFT_GATED);

        assertEq(uint256(checker.mode()), uint256(AllowlistChecker.GatingMode.NFT_GATED));
    }

    function test_SetGatingNFT() public {
        address nft = address(0x1111);
        vm.prank(owner);
        checker.setGatingNFT(nft);
        assertEq(checker.gatingNFT(), nft);
    }

    function test_SetGatingToken() public {
        address token = address(0x2222);
        vm.prank(owner);
        checker.setGatingToken(token, 1000e18);
        assertEq(checker.gatingToken(), token);
        assertEq(checker.gatingTokenThreshold(), 1000e18);
    }

    function test_NFTGatedWithZeroAddressReturnsFalse() public {
        vm.prank(owner);
        checker.setGatingMode(AllowlistChecker.GatingMode.NFT_GATED);
        assertFalse(checker.checkAllowlist(alice, address(0)));
    }

    function test_TokenGatedWithZeroAddressReturnsFalse() public {
        vm.prank(owner);
        checker.setGatingMode(AllowlistChecker.GatingMode.TOKEN_GATED);
        assertFalse(checker.checkAllowlist(alice, address(0)));
    }

    // ---------- Access Control ----------

    function test_SetAllowlistOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        checker.setAllowlist(bob, true);
    }

    function test_SetGatingModeOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        checker.setGatingMode(AllowlistChecker.GatingMode.NFT_GATED);
    }

    // ---------- ERC-165 ----------

    function test_SupportsIAllowlistChecker() public view {
        assertTrue(checker.supportsInterface(type(IAllowlistChecker).interfaceId));
    }

    function test_SupportsIERC165() public view {
        assertTrue(checker.supportsInterface(type(IERC165).interfaceId));
    }

    function test_DoesNotSupportRandomInterface() public view {
        assertFalse(checker.supportsInterface(0xdeadbeef));
    }
}

// ============================================================================
//                          STRATEGY REGISTRY TESTS
// ============================================================================

contract StrategyRegistryTest is Test {
    StrategyRegistry registry;

    address owner = address(0xA11CE);
    address manager = address(0xB0B);
    address vaultA = address(0xAAA);
    address vaultB = address(0xBBB);

    function setUp() public {
        registry = new StrategyRegistry(owner);
    }

    // ---------- Registration ----------

    function test_RegisterStrategy() public {
        uint256 id = registry.registerStrategy(vaultA, manager, "Alpha LP Vault", "ipfs://x");

        assertEq(id, 0);
        assertEq(registry.getStrategyCount(), 1);

        StrategyRegistry.Strategy memory s = registry.getStrategy(0);
        assertEq(s.vault, vaultA);
        assertEq(s.manager, manager);
        assertEq(s.name, "Alpha LP Vault");
        assertTrue(s.active);
    }

    function test_CannotRegisterSameVaultTwice() public {
        registry.registerStrategy(vaultA, manager, "Alpha", "ipfs://a");
        vm.expectRevert("vault already registered");
        registry.registerStrategy(vaultA, manager, "Alpha2", "ipfs://b");
    }

    function test_CannotRegisterZeroVault() public {
        vm.expectRevert("zero vault");
        registry.registerStrategy(address(0), manager, "Alpha", "ipfs://a");
    }

    function test_CannotRegisterZeroManager() public {
        vm.expectRevert("zero manager");
        registry.registerStrategy(vaultA, address(0), "Alpha", "ipfs://a");
    }

    // ---------- Performance Updates ----------

    function test_ManagerCanUpdatePerformance() public {
        uint256 id = registry.registerStrategy(vaultA, manager, "Alpha", "ipfs://a");

        vm.prank(manager);
        registry.updatePerformance(id, 1500, 2e18, 300);

        StrategyRegistry.Strategy memory s = registry.getStrategy(id);
        assertEq(s.apy, 1500);
        assertEq(s.sharpe, 2e18);
        assertEq(s.maxDrawdown, 300);
    }

    function test_OwnerCanUpdatePerformance() public {
        uint256 id = registry.registerStrategy(vaultA, manager, "Alpha", "ipfs://a");

        vm.prank(owner);
        registry.updatePerformance(id, 1500, 2e18, 300);

        StrategyRegistry.Strategy memory s = registry.getStrategy(id);
        assertEq(s.apy, 1500);
    }

    function test_UnauthorizedCannotUpdatePerformance() public {
        uint256 id = registry.registerStrategy(vaultA, manager, "Alpha", "ipfs://a");

        vm.prank(address(0xBAD));
        vm.expectRevert("not authorized");
        registry.updatePerformance(id, 1500, 2e18, 300);
    }

    // ---------- Migration ----------

    function test_MigrateBetweenVaults() public {
        registry.registerStrategy(vaultA, manager, "Alpha", "ipfs://a");
        registry.registerStrategy(vaultB, manager, "Beta", "ipfs://b");

        vm.expectEmit(true, true, true, true);
        emit StrategyRegistry.Migrated(address(this), vaultA, vaultB, 1000e6);

        registry.migrate(vaultA, vaultB, 1000e6);
    }

    function test_MigrateUnregisteredVaultReverts() public {
        registry.registerStrategy(vaultA, manager, "Alpha", "ipfs://a");

        vm.expectRevert("vault not registered");
        registry.migrate(vaultA, vaultB, 1000e6);
    }

    function test_MigrateInactiveVaultReverts() public {
        registry.registerStrategy(vaultA, manager, "Alpha", "ipfs://a");
        registry.registerStrategy(vaultB, manager, "Beta", "ipfs://b");

        vm.prank(manager);
        registry.deactivateStrategy(0);

        vm.expectRevert("from vault inactive");
        registry.migrate(vaultA, vaultB, 1000e6);
    }

    // ---------- Deactivation ----------

    function test_ManagerCanDeactivate() public {
        uint256 id = registry.registerStrategy(vaultA, manager, "Alpha", "ipfs://a");

        vm.prank(manager);
        registry.deactivateStrategy(id);

        StrategyRegistry.Strategy memory s = registry.getStrategy(id);
        assertFalse(s.active);
    }

    function test_OwnerCanDeactivate() public {
        uint256 id = registry.registerStrategy(vaultA, manager, "Alpha", "ipfs://a");

        vm.prank(owner);
        registry.deactivateStrategy(id);

        StrategyRegistry.Strategy memory s = registry.getStrategy(id);
        assertFalse(s.active);
    }

    // ---------- View ----------

    function test_GetActiveStrategies() public {
        registry.registerStrategy(vaultA, manager, "Alpha", "ipfs://a");
        registry.registerStrategy(vaultB, manager, "Beta", "ipfs://b");

        vm.prank(manager);
        registry.deactivateStrategy(0);

        StrategyRegistry.Strategy[] memory active = registry.getActiveStrategies();
        assertEq(active.length, 1);
        assertEq(active[0].vault, vaultB);
    }

    function test_GetInvalidStrategyReverts() public {
        vm.expectRevert("invalid id");
        registry.getStrategy(999);
    }
}

// ============================================================================
//                          INVARIANT TESTS
// ============================================================================

/// @notice Handler that performs bounded random actions on the vault.
contract CuratedVaultHandler is Test {
    CuratedVault public vault;
    MockUSDC public usdc;
    address[] public actors;

    constructor(CuratedVault _vault, MockUSDC _usdc) {
        vault = _vault;
        usdc = _usdc;
        actors.push(address(0x1));
        actors.push(address(0x2));
        actors.push(address(0x3));
        actors.push(address(0x4));
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1e6, 10_000e6);

        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, actor);
        vm.stopPrank();
    }

    function withdraw(uint256 actorSeed, uint256 shares) external {
        address actor = actors[actorSeed % actors.length];
        uint256 bal = vault.balanceOf(actor);
        if (bal == 0) return;

        shares = bound(shares, 1, bal);

        vm.prank(actor);
        vault.redeem(shares, actor, actor);
    }

    function warp(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 7 days);
        vm.warp(block.timestamp + seconds_);
    }

    function harvest() external {
        vault.harvest();
    }
}

contract CuratedVaultInvariants is Test {
    CuratedVault vault;
    MockUSDC usdc;
    CuratedVaultHandler handler;

    function setUp() public {
        usdc = new MockUSDC();
        vault = new CuratedVault(
            usdc,
            "Vault",
            "V",
            address(this),
            address(this),
            0,
            0
        );
        handler = new CuratedVaultHandler(vault, usdc);
        targetContract(address(handler));
    }

    /// @dev Vault must never hold fewer assets than reported totalAssets.
    function invariant_Solvency() public view {
        assertGe(
            usdc.balanceOf(address(vault)) + 1,
            vault.totalAssets(),
            "vault insolvent"
        );
    }

    /// @dev High-water mark must never decrease below initial value.
    function invariant_HwmMonotonic() public view {
        assertGe(vault.highWaterMark(), 1e18, "HWM below initial value");
    }

    /// @dev Sum of actor balances must not exceed total supply.
    function invariant_TotalSupplyConsistent() public view {
        uint256 sumOfActorBalances;
        for (uint256 i = 1; i <= 4; i++) {
            sumOfActorBalances += vault.balanceOf(address(uint160(i)));
        }
        assertLe(sumOfActorBalances, vault.totalSupply());
    }
}