// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.12;

import {OwnableUpgradeable} from "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol";

import {EIP1271SignatureUtils} from "eigenlayer-contracts/src/contracts/libraries/EIP1271SignatureUtils.sol";
import {IPauserRegistry} from "eigenlayer-contracts/src/contracts/interfaces/IPauserRegistry.sol";
import {Pausable} from "eigenlayer-contracts/src/contracts/permissions/Pausable.sol";

import {ISignatureUtils} from "eigenlayer-contracts/src/contracts/interfaces/ISignatureUtils.sol";
import {ISocketUpdater} from "./interfaces/ISocketUpdater.sol";
import {IStakeRegistry} from "./interfaces/IStakeRegistry.sol";
import {IServiceManager} from "./interfaces/IServiceManager.sol";

import {BitmapUtils} from "./libraries/BitmapUtils.sol";

/**
 * @title A `RegistryCoordinator` that has three registries:
 *      1) a `StakeRegistry` that keeps track of operators' stakes
 *      2) a `BLSApkRegistry` that keeps track of operators' BLS public keys and aggregate BLS public keys for each quorum
 *      3) an `IndexRegistry` that keeps track of an ordered list of operators for each quorum
 * 
 * @author Layr Labs, Inc.
 */
contract ECDSARegistryCoordinator is 
    EIP712, 
    Initializable, 
    Pausable,
    OwnableUpgradeable,
    ISocketUpdater, 
    ISignatureUtils
{
    using BitmapUtils for *;

    // EVENTS

    /// Emits when an operator is registered
    event OperatorRegistered(address indexed operator, bytes32 indexed operatorId);

    /// Emits when an operator is deregistered
    event OperatorDeregistered(address indexed operator, bytes32 indexed operatorId);

    event OperatorSetParamsUpdated(uint8 indexed quorumNumber, OperatorSetParam operatorSetParams);

    event ChurnApproverUpdated(address prevChurnApprover, address newChurnApprover);

    event EjectorUpdated(address prevEjector, address newEjector);

    /// @notice emitted when all the operators for a quorum are updated at once
    event QuorumBlockNumberUpdated(uint8 indexed quorumNumber, uint256 blocknumber);

    // DATA STRUCTURES
    enum OperatorStatus
    {
        // default is NEVER_REGISTERED
        NEVER_REGISTERED,
        REGISTERED,
        DEREGISTERED
    }

    // STRUCTS

    /**
     * @notice Data structure for storing info on operators
     */
    struct OperatorInfo {
        // the id of the operator, which is likely the keccak256 hash of the operator's public key if using BLSRegistry
        bytes32 operatorId;
        // indicates whether the operator is actively registered for serving the middleware or not
        OperatorStatus status;
    }

    /**
     * @notice Data structure for storing operator set params for a given quorum. Specifically the 
     * `maxOperatorCount` is the maximum number of operators that can be registered for the quorum,
     * `kickBIPsOfOperatorStake` is the basis points of a new operator needs to have of an operator they are trying to kick from the quorum,
     * and `kickBIPsOfTotalStake` is the basis points of the total stake of the quorum that an operator needs to be below to be kicked.
     */ 
     struct OperatorSetParam {
        uint32 maxOperatorCount;
        uint16 kickBIPsOfOperatorStake;
        uint16 kickBIPsOfTotalStake;
    }

    /**
     * @notice Data structure for the parameters needed to kick an operator from a quorum with number `quorumNumber`, used during registration churn.
     * `operator` is the address of the operator to kick
     */
    struct OperatorKickParam {
        uint8 quorumNumber;
        address operator;
    }

    // TODO: doument
    struct ECDSAPubkeyRegistrationParams {
        address signingAddress;
        SignatureWithSaltAndExpiry signatureAndExpiry;
    }

    /// @notice The EIP-712 typehash for the `DelegationApproval` struct used by the contract
    bytes32 public constant OPERATOR_CHURN_APPROVAL_TYPEHASH =
        keccak256("OperatorChurnApproval(bytes32 registeringOperatorId,OperatorKickParam[] operatorKickParams)OperatorKickParam(address operator,bytes32[] operatorIdsToSwap)");
    /// @notice The EIP-712 typehash used for registering BLS public keys
    bytes32 public constant PUBKEY_REGISTRATION_TYPEHASH = keccak256("ECDSAPubkeyRegistration(address operator)");
    /// @notice The maximum value of a quorum bitmap
    uint256 internal constant MAX_QUORUM_BITMAP = type(uint256).max;
    /// @notice The basis point denominator
    uint16 internal constant BIPS_DENOMINATOR = 10000;
    /// @notice Index for flag that pauses operator registration
    uint8 internal constant PAUSED_REGISTER_OPERATOR = 0;
    /// @notice Index for flag that pauses operator deregistration
    uint8 internal constant PAUSED_DEREGISTER_OPERATOR = 1;
    /// @notice Index for flag pausing operator stake updates
    uint8 internal constant PAUSED_UPDATE_OPERATOR = 2;
    /// @notice The maximum number of quorums this contract supports
    uint8 internal constant MAX_QUORUM_COUNT = 192;

    /// @notice the ServiceManager for this AVS, which forwards calls onto EigenLayer's core contracts
    IServiceManager public immutable serviceManager;
    /// @notice the Stake Registry contract that will keep track of operators' stakes
    IStakeRegistry public immutable stakeRegistry;

    /// @notice the current number of quorums supported by the registry coordinator
    uint8 public quorumCount;
    /// @notice maps quorum number => operator cap and kick params
    mapping(uint8 => OperatorSetParam) internal _quorumParams;
    /// @notice maps operator id => current quorums they are registered for
    mapping(bytes32 => uint256) public operatorBitmap;
    /// @notice maps operator address => operator id and status
    mapping(address => OperatorInfo) internal _operatorInfo;
    /// @notice whether the salt has been used for an operator churn approval
    mapping(bytes32 => bool) public isChurnApproverSaltUsed;
    /// @notice mapping from quorum number to the latest block that all quorums were updated all at once
    mapping(uint8 => uint256) public quorumUpdateBlockNumber;

    // TODO: document
    mapping(bytes32 => address) operatorIdToOperator;
    mapping(uint8 => uint32) public totalOperatorsForQuorum;

    /// @notice the dynamic-length array of the registries this coordinator is coordinating
    address[] public registries;
    /// @notice the address of the entity allowed to sign off on operators getting kicked out of the AVS during registration
    address public churnApprover;
    /// @notice the address of the entity allowed to eject operators from the AVS
    address public ejector;

    modifier onlyEjector {
        require(msg.sender == ejector, "RegistryCoordinator.onlyEjector: caller is not the ejector");
        _;
    }

    modifier quorumExists(uint8 quorumNumber) {
        require(
            quorumNumber < quorumCount, 
            "RegistryCoordinator.quorumExists: quorum does not exist"
        );
        _;
    }

    constructor(
        IServiceManager _serviceManager,
        IStakeRegistry _stakeRegistry
    ) EIP712("AVSRegistryCoordinator", "v0.0.1") {
        serviceManager = _serviceManager;
        stakeRegistry = _stakeRegistry;

        _disableInitializers();
    }

    function initialize(
        address _initialOwner,
        address _churnApprover,
        address _ejector,
        IPauserRegistry _pauserRegistry,
        uint256 _initialPausedStatus,
        OperatorSetParam[] memory _operatorSetParams,
        uint96[] memory _minimumStakes,
        IStakeRegistry.StrategyParams[][] memory _strategyParams
    ) external initializer {
        require(
            _operatorSetParams.length == _minimumStakes.length && _minimumStakes.length == _strategyParams.length,
            "RegistryCoordinator.initialize: input length mismatch"
        );
        
        // Initialize roles
        _transferOwnership(_initialOwner);
        _initializePauser(_pauserRegistry, _initialPausedStatus);
        _setChurnApprover(_churnApprover);
        _setEjector(_ejector);

        // Add registry contracts to the registries array
        registries.push(address(stakeRegistry));

        // Create quorums
        for (uint256 i = 0; i < _operatorSetParams.length; i++) {
            _createQuorum(_operatorSetParams[i], _minimumStakes[i], _strategyParams[i]);
        }
    }

    /*******************************************************************************
                            EXTERNAL FUNCTIONS 
    *******************************************************************************/

    /**
     * @notice Registers msg.sender as an operator for one or more quorums. If any quorum reaches its maximum
     * operator capacity, this method will fail.
     * @param quorumNumbers is an ordered byte array containing the quorum numbers being registered for
     * @param socket is the socket of the operator
     * @param params TODO: document
     * @dev the `params` input param is ignored if the caller has previously registered a public key
     * @param operatorSignature is the signature of the operator used by the AVS to register the operator in the delegation manager
     */
    function registerOperator(
        bytes calldata quorumNumbers,
        string calldata socket,
        ECDSAPubkeyRegistrationParams memory params,
        SignatureWithSaltAndExpiry memory operatorSignature
    ) external onlyWhenNotPaused(PAUSED_REGISTER_OPERATOR) {
        /**
         * IF the operator has never registered a pubkey before, THEN register their pubkey
         * OTHERWISE, simply ignore the provided `params` input
         */
        bytes32 operatorId = _getOrCreateOperatorId(msg.sender, params);

        // Register the operator in each of the registry contracts
        uint32[] memory numOperatorsPerQuorum = _registerOperator({
            operator: msg.sender, 
            operatorId: operatorId,
            quorumNumbers: quorumNumbers, 
            socket: socket,
            operatorSignature: operatorSignature
        }).numOperatorsPerQuorum;

        for (uint256 i = 0; i < quorumNumbers.length; i++) {
            uint8 quorumNumber = uint8(quorumNumbers[i]);
                        
            /**
             * The new operator count for each quorum may not exceed the configured maximum
             * If it does, use `registerOperatorWithChurn` instead.
             */
            require(
                numOperatorsPerQuorum[i] <= _quorumParams[quorumNumber].maxOperatorCount,
                "RegistryCoordinator.registerOperator: operator count exceeds maximum"
            );
        }
    }

    /**
     * @notice Registers msg.sender as an operator for one or more quorums. If any quorum reaches its maximum operator
     * capacity, `operatorKickParams` is used to replace an old operator with the new one.
     * @param quorumNumbers is an ordered byte array containing the quorum numbers being registered for
     * @param params TODO: document
     * @param operatorKickParams are used to determine which operator is removed to maintain quorum capacity as the
     * operator registers for quorums.
     * @param churnApproverSignature is the signature of the churnApprover on the operator kick params
     * @param operatorSignature is the signature of the operator used by the AVS to register the operator in the delegation manager
     * @dev the `params` input param is ignored if the caller has previously registered a public key
     */
    function registerOperatorWithChurn(
        bytes calldata quorumNumbers, 
        string calldata socket,
        ECDSAPubkeyRegistrationParams memory params,
        OperatorKickParam[] calldata operatorKickParams,
        SignatureWithSaltAndExpiry memory churnApproverSignature,
        SignatureWithSaltAndExpiry memory operatorSignature
    ) external onlyWhenNotPaused(PAUSED_REGISTER_OPERATOR) {
        require(operatorKickParams.length == quorumNumbers.length, "RegistryCoordinator.registerOperatorWithChurn: input length mismatch");

        /**
         * IF the operator has never registered a pubkey before, THEN register their pubkey
         * OTHERWISE, simply ignore the provided `params` input
         */
        bytes32 operatorId = _getOrCreateOperatorId(msg.sender, params);

        // Verify the churn approver's signature for the registering operator and kick params
        _verifyChurnApproverSignature({
            registeringOperatorId: operatorId,
            operatorKickParams: operatorKickParams,
            churnApproverSignature: churnApproverSignature
        });

        // Register the operator in each of the registry contracts
        RegisterResults memory results = _registerOperator({
            operator: msg.sender,
            operatorId: operatorId,
            quorumNumbers: quorumNumbers,
            socket: socket,
            operatorSignature: operatorSignature
        });

        for (uint256 i = 0; i < quorumNumbers.length; i++) {
            // reference: uint8 quorumNumber = uint8(quorumNumbers[i]);
            OperatorSetParam memory operatorSetParams = _quorumParams[uint8(quorumNumbers[i])];
            
            /**
             * If the new operator count for any quorum exceeds the maximum, validate
             * that churn can be performed, then deregister the specified operator
             */
            if (results.numOperatorsPerQuorum[i] > operatorSetParams.maxOperatorCount) {
                _validateChurn({
                    quorumNumber: uint8(quorumNumbers[i]),
                    totalQuorumStake: results.totalStakes[i],
                    newOperator: msg.sender,
                    newOperatorStake: results.operatorStakes[i],
                    kickParams: operatorKickParams[i],
                    setParams: operatorSetParams
                });

                _deregisterOperator(operatorKickParams[i].operator, quorumNumbers[i:i+1]);
            }
        }
    }

    /**
     * @notice Deregisters the caller from one or more quorums
     * @param quorumNumbers is an ordered byte array containing the quorum numbers being deregistered from
     */
    function deregisterOperator(
        bytes calldata quorumNumbers
    ) external onlyWhenNotPaused(PAUSED_DEREGISTER_OPERATOR) {
        _deregisterOperator({
            operator: msg.sender, 
            quorumNumbers: quorumNumbers
        });
    }

    /**
     * @notice Updates the stakes of one or more operators in the StakeRegistry, for each quorum
     * the operator is registered for.
     * 
     * If any operator no longer meets the minimum stake required to remain in the quorum,
     * they are deregistered.
     */
    function updateOperators(address[] calldata operators) external onlyWhenNotPaused(PAUSED_UPDATE_OPERATOR) {
        for (uint256 i = 0; i < operators.length; i++) {
            address operator = operators[i];
            OperatorInfo memory operatorInfo = _operatorInfo[operator];
            bytes32 operatorId = operatorInfo.operatorId;

            // Update the operator's stake for their active quorums
            uint256 currentBitmap = _currentOperatorBitmap(operatorId);
            bytes memory quorumsToUpdate = BitmapUtils.bitmapToBytesArray(currentBitmap);
            _updateOperator(operator, operatorInfo, quorumsToUpdate);
        }
    }

    /**
     * @notice Updates the stakes of all operators for each of the specified quorums in the StakeRegistry. Each quorum also
     * has their quorumUpdateBlockNumber updated. which is meant to keep track of when operators were last all updated at once.
     * @param operatorsPerQuorum is an array of arrays of operators to update for each quorum. Note that each nested array
     * of operators must be sorted in ascending address order to ensure that all operators in the quorum are updated
     * @param quorumNumbers is an array of quorum numbers to update
     * @dev This method is used to update the stakes of all operators in a quorum at once, rather than individually. Performs
     * sanitization checks on the input array lengths, quorumNumbers existing, and that quorumNumbers are ordered. Function must
     * also not be paused by the PAUSED_UPDATE_OPERATOR flag.
     */
    function updateOperatorsForQuorum(
        address[][] calldata operatorsPerQuorum,
        bytes calldata quorumNumbers
    ) external onlyWhenNotPaused(PAUSED_UPDATE_OPERATOR) {
        uint256 quorumBitmap = uint256(BitmapUtils.orderedBytesArrayToBitmap(quorumNumbers, quorumCount));
        require(_quorumsAllExist(quorumBitmap), "RegistryCoordinator.updateOperatorsForQuorum: some quorums do not exist");
        require(
            operatorsPerQuorum.length == quorumNumbers.length,
            "RegistryCoordinator.updateOperatorsForQuorum: input length mismatch"
        );

        for (uint256 i = 0; i < quorumNumbers.length; ++i) {
            uint8 quorumNumber = uint8(quorumNumbers[i]);
            address[] calldata currQuorumOperators = operatorsPerQuorum[i];
            require(
                currQuorumOperators.length == totalOperatorsForQuorum[quorumNumber],
                "RegistryCoordinator.updateOperatorsForQuorum: number of updated operators does not match quorum total"
            );
            address prevOperatorAddress = address(0);
            // Update stakes for each operator in this quorum
            for (uint256 j = 0; j < currQuorumOperators.length; ++j) {
                address operator = currQuorumOperators[j];
                OperatorInfo memory operatorInfo = _operatorInfo[operator];
                bytes32 operatorId = operatorInfo.operatorId;
                {
                    uint256 currentBitmap = _currentOperatorBitmap(operatorId);
                    require(
                        BitmapUtils.isSet(currentBitmap, quorumNumber),
                        "RegistryCoordinator.updateOperatorsForQuorum: operator not in quorum"
                    );
                    // Require check is to prevent duplicate operators and that all quorum operators are updated
                    require(
                        operator > prevOperatorAddress,
                        "RegistryCoordinator.updateOperatorsForQuorum: operators array must be sorted in ascending address order"
                    );
                }
                _updateOperator(operator, operatorInfo, quorumNumbers[i:i+1]);
                prevOperatorAddress = operator;
            }

            // Update timestamp that all operators in quorum have been updated all at once
            quorumUpdateBlockNumber[quorumNumber] = block.number;
            emit QuorumBlockNumberUpdated(quorumNumber, block.number);
        }
    }

    /**
     * @notice Updates the socket of the msg.sender given they are a registered operator
     * @param socket is the new socket of the operator
     */
    function updateSocket(string memory socket) external {
        require(_operatorInfo[msg.sender].status == OperatorStatus.REGISTERED, "RegistryCoordinator.updateSocket: operator is not registered");
        emit OperatorSocketUpdate(_operatorInfo[msg.sender].operatorId, socket);
    }

    /*******************************************************************************
                            EXTERNAL FUNCTIONS - EJECTOR
    *******************************************************************************/

    /**
     * @notice Ejects the provided operator from the provided quorums from the AVS
     * @param operator is the operator to eject
     * @param quorumNumbers are the quorum numbers to eject the operator from
     */
    function ejectOperator(
        address operator, 
        bytes calldata quorumNumbers
    ) external onlyEjector {
        _deregisterOperator({
            operator: operator, 
            quorumNumbers: quorumNumbers
        });
    }

    /*******************************************************************************
                            EXTERNAL FUNCTIONS - OWNER
    *******************************************************************************/

    /**
     * @notice Creates a quorum and initializes it in each registry contract
     */
    function createQuorum(
        OperatorSetParam memory operatorSetParams,
        uint96 minimumStake,
        IStakeRegistry.StrategyParams[] memory strategyParams
    ) external virtual onlyOwner {
        _createQuorum(operatorSetParams, minimumStake, strategyParams);
    }

    /**
     * @notice Updates a quorum's OperatorSetParams
     * @param quorumNumber is the quorum number to set the maximum number of operators for
     * @param operatorSetParams is the parameters of the operator set for the `quorumNumber`
     * @dev only callable by the owner
     */
    function setOperatorSetParams(
        uint8 quorumNumber, 
        OperatorSetParam memory operatorSetParams
    ) external onlyOwner quorumExists(quorumNumber) {
        _setOperatorSetParams(quorumNumber, operatorSetParams);
    }

    /**
     * @notice Sets the churnApprover
     * @param _churnApprover is the address of the churnApprover
     * @dev only callable by the owner
     */
    function setChurnApprover(address _churnApprover) external onlyOwner {
        _setChurnApprover(_churnApprover);
    }

    /**
     * @notice Sets the ejector
     * @param _ejector is the address of the ejector
     * @dev only callable by the owner
     */
    function setEjector(address _ejector) external onlyOwner {
        _setEjector(_ejector);
    }

    /*******************************************************************************
                            INTERNAL FUNCTIONS
    *******************************************************************************/

    struct RegisterResults {
        uint32[] numOperatorsPerQuorum;
        uint96[] operatorStakes;
        uint96[] totalStakes;
    }

    /** 
     * @notice Register the operator for one or more quorums. This method updates the
     * operator's quorum bitmap, socket, and status, then registers them with each registry.
     */
    function _registerOperator(
        address operator, 
        bytes32 operatorId,
        bytes calldata quorumNumbers,
        string memory socket,
        SignatureWithSaltAndExpiry memory operatorSignature
    ) internal virtual returns (RegisterResults memory results) {
        /**
         * Get bitmap of quorums to register for and operator's current bitmap. Validate that:
         * - we're trying to register for at least 1 quorum
         * - the operator is not currently registered for any quorums we're registering for
         * Then, calculate the operator's new bitmap after registration
         */
        uint256 quorumsToAdd = uint256(BitmapUtils.orderedBytesArrayToBitmap(quorumNumbers, quorumCount));
        uint256 currentBitmap = _currentOperatorBitmap(operatorId);
        require(!quorumsToAdd.isEmpty(), "RegistryCoordinator._registerOperator: bitmap cannot be 0");
        require(_quorumsAllExist(quorumsToAdd), "RegistryCoordinator._registerOperator: some quorums do not exist");
        require(quorumsToAdd.noBitsInCommon(currentBitmap), "RegistryCoordinator._registerOperator: operator already registered for some quorums being registered for");
        uint256 newBitmap = uint256(currentBitmap.plus(quorumsToAdd));

        /**
         * Update operator's bitmap, socket, and status. Only update operatorInfo if needed:
         * if we're `REGISTERED`, the operatorId and status are already correct.
         */
        _updateOperatorBitmap({
            operatorId: operatorId,
            newBitmap: newBitmap
        });

        emit OperatorSocketUpdate(operatorId, socket);

        if (_operatorInfo[operator].status != OperatorStatus.REGISTERED) {
            _operatorInfo[operator] = OperatorInfo({
                operatorId: operatorId,
                status: OperatorStatus.REGISTERED
            });

            // Register the operator with the EigenLayer via this AVS's ServiceManager
            serviceManager.registerOperatorToAVS(operator, operatorSignature);

            emit OperatorRegistered(operator, operatorId);
        }

        /**
         * Register the operator with the BLSApkRegistry, StakeRegistry, and IndexRegistry
         */
        (results.operatorStakes, results.totalStakes) = 
            stakeRegistry.registerOperator(operator, operatorId, quorumNumbers);
        results.numOperatorsPerQuorum = new uint32[](quorumNumbers.length);
        for (uint256 i = 0; i < quorumNumbers.length; ++i) {
            uint8 quorumNumber = uint8(quorumNumbers[i]);
            uint32 newTotalOperatorsForQuorum = totalOperatorsForQuorum[quorumNumber] + 1;
            totalOperatorsForQuorum[quorumNumber] = newTotalOperatorsForQuorum;
            results.numOperatorsPerQuorum[i] = newTotalOperatorsForQuorum;
        }

        return results;
    }

    function _getOrCreateOperatorId(
        address operator,
        ECDSAPubkeyRegistrationParams memory params
    ) internal returns (bytes32 operatorId) {
        operatorId = _operatorInfo[operator].operatorId;
        if (operatorId == 0) {
            operatorId = _registerECDSAPublicKey(operator, params, pubkeyRegistrationMessageHash(operator));
        }
        return operatorId;
    }

    function _registerECDSAPublicKey(
        address operator,
        ECDSAPubkeyRegistrationParams memory params,
        bytes32 _pubkeyRegistrationMessageHash
    ) internal returns (bytes32 operatorId) {
        require(
            params.signingAddress != address(0),
            "ECDSARegistryCoordinator._registerECDSAPublicKey: cannot register zero pubkey"
        );
        require(
            _operatorInfo[operator].operatorId == bytes32(0),
            "ECDSARegistryCoordinator._registerECDSAPublicKey: operator already registered pubkey"
        );

        operatorId = bytes32(uint256(uint160(params.signingAddress)));
        require(
            operatorIdToOperator[operatorId] == address(0),
            "ECDSARegistryCoordinator._registerECDSAPublicKey: public key already registered"
        );

        // check the signature expiry
        require(
            params.signatureAndExpiry.expiry >= block.timestamp,
            "ECDSARegistryCoordinator._registerECDSAPublicKey: signature expired"
        );

        // actually check that the signature is valid
        EIP1271SignatureUtils.checkSignature_EIP1271(params.signingAddress, _pubkeyRegistrationMessageHash, params.signatureAndExpiry.signature);

        operatorIdToOperator[operatorId] = operator;

        // TODO: event
        // emit NewPubkeyRegistration(operator, params.pubkeyG1, params.pubkeyG2);
        return operatorId;
    }

    function _validateChurn(
        uint8 quorumNumber, 
        uint96 totalQuorumStake,
        address newOperator, 
        uint96 newOperatorStake,
        OperatorKickParam memory kickParams, 
        OperatorSetParam memory setParams
    ) internal view {
        address operatorToKick = kickParams.operator;
        bytes32 idToKick = _operatorInfo[operatorToKick].operatorId;
        require(newOperator != operatorToKick, "RegistryCoordinator._validateChurn: cannot churn self");
        require(kickParams.quorumNumber == quorumNumber, "RegistryCoordinator._validateChurn: quorumNumber not the same as signed");

        // Get the target operator's stake and check that it is below the kick thresholds
        uint96 operatorToKickStake = stakeRegistry.getCurrentStake(idToKick, quorumNumber);
        require(
            newOperatorStake > _individualKickThreshold(operatorToKickStake, setParams),
            "RegistryCoordinator._validateChurn: incoming operator has insufficient stake for churn"
        );
        require(
            operatorToKickStake < _totalKickThreshold(totalQuorumStake, setParams),
            "RegistryCoordinator._validateChurn: cannot kick operator with more than kickBIPsOfTotalStake"
        );
    }

    /**
     * @dev Deregister the operator from one or more quorums
     * This method updates the operator's quorum bitmap and status, then deregisters
     * the operator with the BLSApkRegistry, IndexRegistry, and StakeRegistry
     */
    function _deregisterOperator(
        address operator, 
        bytes memory quorumNumbers
    ) internal virtual {
        // Fetch the operator's info and ensure they are registered
        OperatorInfo storage operatorInfo = _operatorInfo[operator];
        bytes32 operatorId = operatorInfo.operatorId;
        require(operatorInfo.status == OperatorStatus.REGISTERED, "RegistryCoordinator._deregisterOperator: operator is not registered");
        
        /**
         * Get bitmap of quorums to deregister from and operator's current bitmap. Validate that:
         * - we're trying to deregister from at least 1 quorum
         * - the operator is currently registered for any quorums we're trying to deregister from
         * Then, calculate the opreator's new bitmap after deregistration
         */
        uint256 quorumsToRemove = uint256(BitmapUtils.orderedBytesArrayToBitmap(quorumNumbers, quorumCount));
        uint256 currentBitmap = _currentOperatorBitmap(operatorId);
        require(!quorumsToRemove.isEmpty(), "RegistryCoordinator._deregisterOperator: bitmap cannot be 0");
        require(_quorumsAllExist(quorumsToRemove), "RegistryCoordinator._deregisterOperator: some quorums do not exist");
        require(quorumsToRemove.isSubsetOf(currentBitmap), "RegistryCoordinator._deregisterOperator: operator is not registered for specified quorums");
        uint256 newBitmap = uint256(currentBitmap.minus(quorumsToRemove));

        /**
         * Update operator's bitmap and status:
         */
        _updateOperatorBitmap({
            operatorId: operatorId,
            newBitmap: newBitmap
        });

        // If the operator is no longer registered for any quorums, update their status and deregister from EigenLayer via this AVS's ServiceManager
        if (newBitmap.isEmpty()) {
            operatorInfo.status = OperatorStatus.DEREGISTERED;
            serviceManager.deregisterOperatorFromAVS(operator);
            emit OperatorDeregistered(operator, operatorId);
        }

        // Deregister operator with each of the registry contracts:
        stakeRegistry.deregisterOperator(operatorId, quorumNumbers);
        for (uint256 i = 0; i < quorumNumbers.length; ++i) {
            uint8 quorumNumber = uint8(quorumNumbers[i]);
            --totalOperatorsForQuorum[quorumNumber];
        }
    }

    /**
     * @notice update operator stake for specified quorumsToUpdate, and deregister if necessary
     * does nothing if operator is not registered for any quorums.
     */
    function _updateOperator(
        address operator,
        OperatorInfo memory operatorInfo,
        bytes memory quorumsToUpdate
    ) internal {
        if (operatorInfo.status != OperatorStatus.REGISTERED) {
            return;
        }
        bytes32 operatorId = operatorInfo.operatorId;
        uint256 quorumsToRemove = stakeRegistry.updateOperatorStake(operator, operatorId, quorumsToUpdate);

        if (!quorumsToRemove.isEmpty()) {
            _deregisterOperator({
                operator: operator,
                quorumNumbers: BitmapUtils.bitmapToBytesArray(quorumsToRemove)
            });    
        }
    }

    /**
     * @notice Returns the stake threshold required for an incoming operator to replace an existing operator
     * The incoming operator must have more stake than the return value.
     */
    function _individualKickThreshold(uint96 operatorStake, OperatorSetParam memory setParams) internal pure returns (uint96) {
        return operatorStake * setParams.kickBIPsOfOperatorStake / BIPS_DENOMINATOR;
    }

    /**
     * @notice Returns the total stake threshold required for an operator to remain in a quorum.
     * The operator must have at least the returned stake amount to keep their position.
     */
    function _totalKickThreshold(uint96 totalStake, OperatorSetParam memory setParams) internal pure returns (uint96) {
        return totalStake * setParams.kickBIPsOfTotalStake / BIPS_DENOMINATOR;
    }

    /// @notice verifies churnApprover's signature on operator churn approval and increments the churnApprover nonce
    function _verifyChurnApproverSignature(
        bytes32 registeringOperatorId, 
        OperatorKickParam[] memory operatorKickParams, 
        SignatureWithSaltAndExpiry memory churnApproverSignature
    ) internal {
        // make sure the salt hasn't been used already
        require(!isChurnApproverSaltUsed[churnApproverSignature.salt], "RegistryCoordinator._verifyChurnApproverSignature: churnApprover salt already used");
        require(churnApproverSignature.expiry >= block.timestamp, "RegistryCoordinator._verifyChurnApproverSignature: churnApprover signature expired");   

        // set salt used to true
        isChurnApproverSaltUsed[churnApproverSignature.salt] = true;    

        // check the churnApprover's signature 
        EIP1271SignatureUtils.checkSignature_EIP1271(
            churnApprover, 
            calculateOperatorChurnApprovalDigestHash(registeringOperatorId, operatorKickParams, churnApproverSignature.salt, churnApproverSignature.expiry), 
            churnApproverSignature.signature
        );
    }

    /**
     * @notice Creates and initializes a quorum in each registry contract
     */
    function _createQuorum(
        OperatorSetParam memory operatorSetParams,
        uint96 minimumStake,
        IStakeRegistry.StrategyParams[] memory strategyParams
    ) internal {
        // Increment the total quorum count. Fails if we're already at the max
        uint8 prevQuorumCount = quorumCount;
        require(prevQuorumCount < MAX_QUORUM_COUNT, "RegistryCoordinator.createQuorum: max quorums reached");
        quorumCount = prevQuorumCount + 1;
        
        // The previous count is the new quorum's number
        uint8 quorumNumber = prevQuorumCount;

        // Initialize the quorum here and in each registry
        _setOperatorSetParams(quorumNumber, operatorSetParams);
        stakeRegistry.initializeQuorum(quorumNumber, minimumStake, strategyParams);
    }

    /**
     * @notice Record an update to an operator's quorum bitmap.
     * @param newBitmap is the most up-to-date set of bitmaps the operator is registered for
     */
    function _updateOperatorBitmap(bytes32 operatorId, uint256 newBitmap) internal {
        operatorBitmap[operatorId] = newBitmap;
    }

    /**
     * @notice Returns true iff all of the bits in `quorumBitmap` belong to initialized quorums
     */
     function _quorumsAllExist(uint256 quorumBitmap) internal view returns (bool) {
        uint256 initializedQuorumBitmap = uint256((1 << quorumCount) - 1);
        return quorumBitmap.isSubsetOf(initializedQuorumBitmap);
    }

    /// @notice Get the most recent bitmap for the operator, returning an empty bitmap if
    /// the operator is not registered.
    function _currentOperatorBitmap(bytes32 operatorId) internal view returns (uint256) {
        return operatorBitmap[operatorId];
    }

    function _setOperatorSetParams(uint8 quorumNumber, OperatorSetParam memory operatorSetParams) internal {
        _quorumParams[quorumNumber] = operatorSetParams;
        emit OperatorSetParamsUpdated(quorumNumber, operatorSetParams);
    }
    
    function _setChurnApprover(address newChurnApprover) internal {
        emit ChurnApproverUpdated(churnApprover, newChurnApprover);
        churnApprover = newChurnApprover;
    }

    function _setEjector(address newEjector) internal {
        emit EjectorUpdated(ejector, newEjector);
        ejector = newEjector;
    }

    /*******************************************************************************
                            VIEW FUNCTIONS
    *******************************************************************************/

    /// @notice Returns the operator set params for the given `quorumNumber`
    function getOperatorSetParams(uint8 quorumNumber) external view returns (OperatorSetParam memory) {
        return _quorumParams[quorumNumber];
    }

    /// @notice Returns the operator struct for the given `operator`
    function getOperator(address operator) external view returns (OperatorInfo memory) {
        return _operatorInfo[operator];
    }

    /// @notice Returns the operatorId for the given `operator`
    function getOperatorId(address operator) external view returns (bytes32) {
        return _operatorInfo[operator].operatorId;
    }

    /// @notice Returns the operator address for the given `operatorId`
    function getOperatorFromId(bytes32 operatorId) external view returns (address) {
        return operatorIdToOperator[operatorId];
    }

    /// @notice Returns the status for the given `operator`
    function getOperatorStatus(address operator) external view returns (OperatorStatus) {
        return _operatorInfo[operator].status;
    }

    /// @notice Returns the current quorum bitmap for the given `operatorId` or 0 if the operator is not registered for any quorum
    function getCurrentQuorumBitmap(bytes32 operatorId) external view returns (uint256) {
        return _currentOperatorBitmap(operatorId);
    }

    /// @notice Returns the number of registries
    function numRegistries() external view returns (uint256) {
        return registries.length;
    }

    /**
     * @notice Public function for the the churnApprover signature hash calculation when operators are being kicked from quorums
     * @param registeringOperatorId The is of the registering operator 
     * @param operatorKickParams The parameters needed to kick the operator from the quorums that have reached their caps
     * @param salt The salt to use for the churnApprover's signature
     * @param expiry The desired expiry time of the churnApprover's signature
     */
    function calculateOperatorChurnApprovalDigestHash(
        bytes32 registeringOperatorId,
        OperatorKickParam[] memory operatorKickParams,
        bytes32 salt,
        uint256 expiry
    ) public view returns (bytes32) {
        // calculate the digest hash
        return _hashTypedDataV4(keccak256(abi.encode(OPERATOR_CHURN_APPROVAL_TYPEHASH, registeringOperatorId, operatorKickParams, salt, expiry)));
    }

    /**
     * @notice Returns the message hash that an operator must sign to register their BLS public key.
     * @param operator is the address of the operator registering their BLS public key
     */
    function pubkeyRegistrationMessageHash(address operator) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(PUBKEY_REGISTRATION_TYPEHASH, operator))
        );
    }

    /// @dev need to override function here since its defined in both these contracts
    function owner()
        public
        view
        override(OwnableUpgradeable)
        returns (address)
    {
        return OwnableUpgradeable.owner();
    }
}