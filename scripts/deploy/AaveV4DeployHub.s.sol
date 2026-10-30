// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity ^0.8.0;

import {Script, console2 as console} from 'forge-std/Script.sol';
import {BatchReports} from 'src/deployments/libraries/BatchReports.sol';
import {AaveV4DeployBase} from 'src/deployments/orchestration/AaveV4DeployBase.sol';
import {AaveV4DeployOrchestration} from 'src/deployments/orchestration/AaveV4DeployOrchestration.sol';
import {BytecodeHelper} from 'src/deployments/utils/libraries/BytecodeHelper.sol';
import {Create2Utils} from 'src/deployments/utils/libraries/Create2Utils.sol';
import {ERC1967Utils} from 'src/dependencies/openzeppelin/ERC1967Utils.sol';
import {IAccessManaged} from 'src/dependencies/openzeppelin/IAccessManaged.sol';
import {IAccessManager} from 'src/dependencies/openzeppelin/IAccessManager.sol';
import {IHub} from 'src/hub/interfaces/IHub.sol';

interface IOwnableMin {
  function owner() external view returns (address);
}

/// @title AaveV4DeployHub
/// @notice Minimal Hub deployment for any EVM chain: one AccessManager and one Hub (implementation +
/// proxy + AssetInterestRateStrategy). It is a cut-down copy of `AaveV4DeployBatchBaseScript` and
/// reuses the same batches and salt derivation, but deploys none of the other framework contracts: no
/// configurators, TreasurySpoke, Spokes, AaveOracle, LiquidationLogic, gateways or position managers,
/// and it sets no role labels or function-role mappings.
/// @dev The chain is never assumed: `DEPLOY_CHAIN_ID` must name it and the run reverts on any other
/// chain. Subclasses can pin a chain (and a default salt) in code instead; see
/// `AaveV4DeployHubSepolia` and `AaveV4DeployHubArbitrumSepolia`.
/// @dev Hub admin functions are therefore callable only by members of the AccessManager's ADMIN_ROLE
/// (`ACCESS_MANAGER_ADMIN`), directly on the Hub proxy. Bring your own Spoke, list assets with
/// `hub.addAsset` and register the Spoke with `hub.addSpoke`.
///
/// Inputs (env vars; unset or zero addresses default to the deployer, with a warning):
///   DEPLOY_CHAIN_ID       required: chain id this run is allowed to deploy to (e.g. 421614)
///   ACCESS_MANAGER_ADMIN  root admin of the AccessManager; controls every restricted Hub function
///   PROXY_ADMIN_OWNER     owner of the Hub's ProxyAdmin; can upgrade the Hub implementation
///   HUB_LABEL             label mixed into the Hub's CREATE2 salt (default 'test')
///   DEPLOY_SALT           bytes32 mixed into every CREATE2 salt. The same deployer, salt and admins
///                         give the same addresses on every chain; change it to get different ones.
///   SKIP_PROMPT=true      skip the interactive y/n confirmation
///
/// Requires the Safe Singleton Factory at Create2Utils.CREATE2_FACTORY. Present on Ethereum Sepolia,
/// Arbitrum One and Arbitrum Sepolia; the run reverts on a chain without it.
///
/// Usage (dry run: drop --broadcast; add --verify --etherscan-api-key $ETHERSCAN_API_KEY to verify):
///   DEPLOY_CHAIN_ID=<chain id> forge script scripts/deploy/AaveV4DeployHub.s.sol:AaveV4DeployHub \
///     --skip test --rpc-url $RPC_URL --account <keystore-name> --slow --broadcast
/// Add `--gas-estimate-multiplier <n>` where Foundry's local gas estimate is too low (Ethereum Sepolia
/// after its 2026-10-06 fork, and L2s that charge for L1 data such as Arbitrum).
contract AaveV4DeployHub is Script {
  struct HubOnlyInputs {
    address accessManagerAdmin;
    address proxyAdminOwner;
    string hubLabel;
    bytes32 salt;
  }

  string internal constant OUTPUT_DIR = 'output/reports/deployments/';

  string[] internal _promptLines;

  /// @notice Deploys the AccessManager and the Hub, checks the result and writes a JSON report.
  function run() external virtual {
    _validateChainId();
    require(
      Create2Utils.isContractDeployed(Create2Utils.CREATE2_FACTORY),
      'CREATE2 factory not deployed on this chain'
    );
    HubOnlyInputs memory inputs = _getDeployInputs();

    vm.startBroadcast();
    (, address deployer, ) = vm.readCallers();
    inputs = _sanitizeInputs(inputs, deployer);

    bytes32 rootSalt = AaveV4DeployOrchestration._deriveSalt({deployer: deployer, salt: inputs.salt});
    bytes32 hubSalt = AaveV4DeployOrchestration._deriveChildSalt(rootSalt, 'hub', inputs.hubLabel);

    BatchReports.AuthorityBatchReport memory authorityReport = AaveV4DeployBase
      .deployAuthorityBatch({admin: inputs.accessManagerAdmin, salt: rootSalt});

    BatchReports.HubInstanceBatchReport memory hubReport = AaveV4DeployBase.deployHubInstanceBatch({
      proxyAdminOwner: inputs.proxyAdminOwner,
      authority: authorityReport.accessManager,
      hubBytecode: BytecodeHelper.getHubBytecode(),
      salt: hubSalt
    });
    vm.stopBroadcast();

    _verifyDeployment(inputs, authorityReport, hubReport);
    _logReport(deployer, inputs, authorityReport, hubReport);
    _writeReport(deployer, inputs, authorityReport, hubReport);
  }

  /// @dev Override to hard-code inputs instead of reading env vars.
  function _getDeployInputs() internal virtual returns (HubOnlyInputs memory) {
    return
      HubOnlyInputs({
        accessManagerAdmin: vm.envOr('ACCESS_MANAGER_ADMIN', address(0)),
        proxyAdminOwner: vm.envOr('PROXY_ADMIN_OWNER', address(0)),
        hubLabel: vm.envOr('HUB_LABEL', string('test')),
        salt: vm.envOr('DEPLOY_SALT', _defaultSalt())
      });
  }

  /// @dev Salt used when `DEPLOY_SALT` is unset. Override to keep an existing deployment's addresses.
  function _defaultSalt() internal pure virtual returns (bytes32) {
    return keccak256('aave-v4-hub-test');
  }

  /// @dev The one chain this run may deploy to. Reads `DEPLOY_CHAIN_ID`; a subclass can return a
  /// constant instead. Never defaults to a chain, so a forgotten variable stops the run.
  function _expectedChainId() internal view virtual returns (uint256) {
    return vm.envOr('DEPLOY_CHAIN_ID', uint256(0));
  }

  function _validateChainId() internal view virtual {
    uint256 expected = _expectedChainId();
    require(expected != 0, 'DEPLOY_CHAIN_ID is not set');
    require(block.chainid == expected, 'chain id mismatch');
  }

  function _sanitizeInputs(
    HubOnlyInputs memory inputs,
    address deployer
  ) internal virtual returns (HubOnlyInputs memory) {
    string memory message = ' is zero address';
    string memory outcome = string.concat('; defaulting to deployer [', vm.toString(deployer), ']');

    require(bytes(inputs.hubLabel).length > 0, 'hub label is empty');
    if (inputs.accessManagerAdmin == address(0)) {
      _promptLines.push(string.concat('WARNING: access manager admin', message, outcome));
      inputs.accessManagerAdmin = deployer;
    }
    if (inputs.proxyAdminOwner == address(0)) {
      _promptLines.push(string.concat('WARNING: proxy admin owner', message, outcome));
      inputs.proxyAdminOwner = deployer;
    }
    if (inputs.accessManagerAdmin == inputs.proxyAdminOwner) {
      _promptLines.push('WARNING: access manager admin and proxy admin owner are the same address');
    }
    if (inputs.salt == bytes32(0)) {
      _promptLines.push('WARNING: salt is zero');
    }

    _promptLines.push('========== DEPLOYMENT SUMMARY ==========');
    _promptLines.push(string.concat('chain id: ', vm.toString(block.chainid)));
    _promptLines.push(string.concat('deployer: ', vm.toString(deployer)));
    _promptLines.push(
      string.concat('access manager admin: ', vm.toString(inputs.accessManagerAdmin))
    );
    _promptLines.push(string.concat('proxy admin owner: ', vm.toString(inputs.proxyAdminOwner)));
    _promptLines.push(string.concat('hub label: ', inputs.hubLabel));
    _promptLines.push('deploys: AccessManager, Hub (implementation + proxy), AssetInterestRateStrategy');
    _promptLines.push('--------------------------------------------------');
    _executeUserPrompt();
    return inputs;
  }

  function _executeUserPrompt() internal virtual {
    if (vm.envOr('SKIP_PROMPT', false)) {
      return;
    }
    string memory lines;
    for (uint256 i; i < _promptLines.length; i++) {
      lines = string.concat(lines, _promptLines[i], '\n');
    }
    string memory ack = vm.prompt(string.concat(lines, "enter 'y' to continue"));
    if (keccak256(bytes(ack)) != keccak256(bytes('y'))) {
      revert('user did not acknowledge. Please try again.');
    }
  }

  /// @dev Sanity checks on what was just deployed.
  function _verifyDeployment(
    HubOnlyInputs memory inputs,
    BatchReports.AuthorityBatchReport memory authorityReport,
    BatchReports.HubInstanceBatchReport memory hubReport
  ) internal view virtual {
    require(
      IAccessManaged(hubReport.hubProxy).authority() == authorityReport.accessManager,
      'hub authority mismatch'
    );
    (bool isAdmin, ) = IAccessManager(authorityReport.accessManager).hasRole(
      0,
      inputs.accessManagerAdmin
    );
    require(isAdmin, 'access manager admin does not hold ADMIN_ROLE');
    address proxyAdmin = address(
      uint160(uint256(vm.load(hubReport.hubProxy, ERC1967Utils.ADMIN_SLOT)))
    );
    require(
      IOwnableMin(proxyAdmin).owner() == inputs.proxyAdminOwner,
      'proxy admin owner mismatch'
    );
    require(IHub(hubReport.hubProxy).getAssetCount() == 0, 'hub is not empty');
  }

  function _logReport(
    address deployer,
    HubOnlyInputs memory inputs,
    BatchReports.AuthorityBatchReport memory authorityReport,
    BatchReports.HubInstanceBatchReport memory hubReport
  ) internal view virtual {
    console.log('CHAIN ID', block.chainid);
    console.log('deployer', deployer);
    console.log('access manager admin', inputs.accessManagerAdmin);
    console.log('proxy admin owner', inputs.proxyAdminOwner);
    console.log('AccessManager', authorityReport.accessManager);
    console.log('Hub (proxy)', hubReport.hubProxy);
    console.log('HubImplementation', hubReport.hubImplementation);
    console.log('AssetInterestRateStrategy', hubReport.irStrategy);
  }

  function _writeReport(
    address deployer,
    HubOnlyInputs memory inputs,
    BatchReports.AuthorityBatchReport memory authorityReport,
    BatchReports.HubInstanceBatchReport memory hubReport
  ) internal virtual {
    string memory obj = 'hubOnlyReport';
    vm.serializeUint(obj, 'chainId', block.chainid);
    vm.serializeAddress(obj, 'deployer', deployer);
    vm.serializeBytes32(obj, 'salt', inputs.salt);
    vm.serializeString(obj, 'hubLabel', inputs.hubLabel);
    vm.serializeAddress(obj, 'accessManagerAdmin', inputs.accessManagerAdmin);
    vm.serializeAddress(obj, 'proxyAdminOwner', inputs.proxyAdminOwner);
    vm.serializeAddress(obj, 'accessManager', authorityReport.accessManager);
    vm.serializeAddress(obj, 'hubImplementation', hubReport.hubImplementation);
    vm.serializeAddress(obj, 'irStrategy', hubReport.irStrategy);
    string memory json = vm.serializeAddress(obj, 'hub', hubReport.hubProxy);

    vm.createDir(OUTPUT_DIR, true);
    vm.writeJson(
      json,
      string.concat(
        OUTPUT_DIR,
        vm.toString(block.timestamp),
        '-',
        vm.toString(block.chainid),
        '-hub-only.json'
      )
    );
  }
}
