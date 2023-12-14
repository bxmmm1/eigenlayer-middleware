// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.12;

import {OwnableUpgradeable} from "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";

import {BitmapUtils} from "src/libraries/BitmapUtils.sol"; 
import {ISignatureUtils} from "eigenlayer-contracts/src/contracts/interfaces/ISignatureUtils.sol";
import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";

import {IServiceManager} from "src/interfaces/IServiceManager.sol";
import {IRegistryCoordinator} from "src/interfaces/IRegistryCoordinator.sol";
import {IStakeRegistry} from "src/interfaces/IStakeRegistry.sol";

/**
 * @title Minimal implementation of a ServiceManager-type contract.
 * This contract can inherited from or simply used as a point-of-reference.
 * @author Layr Labs, Inc.
 */
contract ServiceManagerBase is IServiceManager, OwnableUpgradeable {
    using BitmapUtils for *;

    IRegistryCoordinator immutable registryCoordinator;
    IDelegationManager immutable delegationManager;
    IStakeRegistry immutable stakeRegistry;

    /// @notice when applied to a function, only allows the RegistryCoordinator to call it
    modifier onlyRegistryCoordinator() {
        require(
            msg.sender == address(registryCoordinator),
            "ServiceManagerBase.onlyRegistryCoordinator: caller is not the registry coordinator"
        );
        _;
    }

    /// @notice Sets the (immutable) `registryCoordinator` address
    constructor(
        IDelegationManager _delegationManager,
        IRegistryCoordinator _registryCoordinator,
        IStakeRegistry _stakeRegistry
    ) {
        delegationManager = _delegationManager;
        registryCoordinator = _registryCoordinator;
        stakeRegistry = _stakeRegistry;
        _disableInitializers();
    }

    function initialize(address initialOwner) external initializer {
        _transferOwnership(initialOwner);
    }

    /**
     * @notice Sets the metadata URI for the AVS
     * @param _metadataURI is the metadata URI for the AVS
     * @dev only callable by the owner
     */
    function setMetadataURI(string memory _metadataURI) public virtual onlyOwner {
        delegationManager.updateAVSMetadataURI(_metadataURI);
    }

    /**
     * @notice Forwards a call to EigenLayer's DelegationManager contract to confirm operator registration with the AVS
     * @param operator The address of the operator to register.
     * @param operatorSignature The signature, salt, and expiry of the operator's signature.
     */
    function registerOperatorToAVS(
        address operator,
        ISignatureUtils.SignatureWithSaltAndExpiry memory operatorSignature
    ) public virtual onlyRegistryCoordinator {
        delegationManager.registerOperatorToAVS(operator, operatorSignature);
    }

    /**
     * @notice Forwards a call to EigenLayer's DelegationManager contract to confirm operator deregistration from the AVS
     * @param operator The address of the operator to deregister.
     */
    function deregisterOperatorFromAVS(address operator) public virtual onlyRegistryCoordinator {
        delegationManager.deregisterOperatorFromAVS(operator);
    }

    /**
     * @notice Returns the list of strategies that the operator has potentially restaked on the AVS
     * @param operator The address of the operator to get restaked strategies for
     * @dev This function is intended to be called off-chain
     * @dev No guarantee is made on whether the operator has shares for a strategy in a quorum or uniqueness 
     *      of each element in the returned array. The off-chain service should do that validation separately
     */
    function getOperatorRestakedStrategies(address operator) external view returns (address[] memory) {
        bytes32 operatorId = registryCoordinator.getOperatorId(operator);
        uint192 operatorBitmap = registryCoordinator.getCurrentQuorumBitmap(operatorId);

        if (operatorBitmap == 0 || registryCoordinator.quorumCount() == 0) {
            return new address[](0);
        }

        // Get number of strategies for each quorum in operator bitmap
        bytes memory operatorRestakedQuorums = BitmapUtils.bitmapToBytesArray(operatorBitmap);
        uint256 strategyCount;
        for(uint256 i = 0; i < operatorRestakedQuorums.length; i++) {
            strategyCount += stakeRegistry.strategyParamsLength(uint8(operatorRestakedQuorums[i]));
        }

        // Get strategies for each quorum in operator bitmap
        address[] memory restakedStrategies = new address[](strategyCount);
        uint256 index = 0;
        for(uint256 i = 0; i < operatorRestakedQuorums.length; i++) {
            uint8 quorum = uint8(operatorRestakedQuorums[i]);
            uint256 strategyParamsLength = stakeRegistry.strategyParamsLength(quorum);
            for (uint256 j = 0; j < strategyParamsLength; j++) {
                restakedStrategies[index] = address(stakeRegistry.strategyParamsByIndex(quorum, j).strategy);
                index++;
            }
        }
        return restakedStrategies;        
    }
}
