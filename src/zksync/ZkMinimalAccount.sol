// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// zkSync Era imports
import {IAccount, ACCOUNT_VALIDATION_SUCCESS_MAGIC} from 
"lib/foundry-era-contracts/src/system-contracts/contracts/interfaces/IAccount.sol";
import {Transaction, MemoryTransactionHelper} from 
"lib/foundry-era-contracts/src/system-contracts/contracts/libraries/MemoryTransactionHelper.sol";
import {SystemContractsCaller} from "lib/foundry-era-contracts/src/system-contracts/contracts/libraries/SystemContractsCaller.sol";
import {NONCE_HOLDER_SYSTEM_CONTRACT, BOOTLOADER_FORMAL_ADDRESS, DEPLOYER_SYSTEM_CONTRACT} from 
"lib/foundry-era-contracts/src/system-contracts/contracts/Constants.sol";
import {INonceHolder} from "lib/foundry-era-contracts/src/system-contracts/contracts/interfaces/INonceHolder.sol";
import {Utils} from "lib/foundry-era-contracts/src/system-contracts/contracts/libraries/Utils.sol";

// OZ imports
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
/**

 * Lifecycle of a type 113 (0x71) transaction
 / msg.sender is the bootloader contract, which is the only contract that can call this contract.    
 
 * Phase 1 Validation
 1. The user sends the transaction to the "zkSync API client" (short of "light node").
 2. The zkSync API client checks to see if the nonce is unique by querying the ç
    NonceHolder system contract.
 3. The zkSync API client calls validateTransaction, which must update the nonce.
 4. The zkSync API client checks the nonce is updated.
 5. The zkSync API client calls payForTransaction or prepareforPaymaster & validateAndPayForPaymasterTransaction.
 6. The zkSync API client verifies that the bootloader gets paid.

 * Phase 2 Execution
 7. The zkSync API client passes the validated transaction to the main node/sequencer.
 8. The main node calls executeTransaction.
 9. If Paymaster was used, the postTransaction is called.

 */


contract ZkMinimalAccount is IAccount, Ownable {
    using MemoryTransactionHelper for Transaction;

    /** ERRORS */

    error ZkMinimalAccount__InsufficientBalance();
    error ZkMinimalAccount__NotFromBootLoader();
    error ZkMinimalAccount__NotFromBootLoaderOrOwner();
    error ZkMinimalAccount__ExecutionFailed();  
    error ZkMinimalAccount__FailedToPay();
    error ZkMinimalAccount__InvalidSignature();

    /** MODIFIERS */
    modifier requireFromBootLoader(){
        if (msg.sender != BOOTLOADER_FORMAL_ADDRESS) {
            revert ZkMinimalAccount__NotFromBootLoader();
        }
        _;
    }

    modifier requireFromBootLoaderOrOwner(){
        if (msg.sender != BOOTLOADER_FORMAL_ADDRESS && msg.sender != owner()) {
            revert ZkMinimalAccount__NotFromBootLoaderOrOwner();
        }
        _;
    }

    /**FUNCTIONS */
    constructor() Ownable(msg.sender) {}

    receive() external payable {}

    /**EXTERNAL FUNCTIONS */

    /**
     * @notice must increase the nonce.
     * @notice must validate the tx (check the owner signed the tx).
     * @notice also check if we have enough money in the account.
     */

    function validateTransaction(bytes32 /*_txHash*/, bytes32 /*_suggestedSignedHash*/, Transaction memory _transaction)
        external
        payable
        requireFromBootLoader
        returns (bytes4 magic)
    {
        _validateTransaction(_transaction);
    }

    function executeTransaction(bytes32 /*_txHash*/, bytes32 /*_suggestedSignedHash*/, Transaction memory _transaction)
        external
        payable
        requireFromBootLoaderOrOwner
    {
        _executeTransaction(_transaction);
    }

    function executeTransactionFromOutside(Transaction memory _transaction) external payable
    {
        bytes4 magic = _validateTransaction(_transaction);
        if (magic != ACCOUNT_VALIDATION_SUCCESS_MAGIC){
            revert ZkMinimalAccount__InvalidSignature();
        }
        _executeTransaction(_transaction);  
    }

    function payForTransaction(bytes32 /*_txHash*/, bytes32 /*_suggestedSignedHash*/, Transaction memory _transaction)
        external
        payable
    {
       bool success = _transaction.payToTheBootloader();
       if (!success) {
           revert ZkMinimalAccount__FailedToPay();
       }
    }

    function prepareForPaymaster(bytes32 _txHash, bytes32 _possibleSignedHash, Transaction memory _transaction)
        external
        payable
    {}

    /** INTERNAL FUNCTIONS */

    function _validateTransaction (Transaction memory _transaction) internal returns (bytes4 magic) {
        // call NonceHolder
        // increment nonce
        // call (x, y, z) => systme contract call

        SystemContractsCaller.systemCallWithPropagatedRevert(
            uint32(gasleft()),
            address(NONCE_HOLDER_SYSTEM_CONTRACT),  
            0,
            abi.encodeCall(INonceHolder.incrementMinNonceIfEquals, (_transaction.nonce))
        );

        // Check for fee to pay
        uint totalRequiredBalance = _transaction.totalRequiredBalance();
        if(totalRequiredBalance > address(this).balance) {
            revert ZkMinimalAccount__InsufficientBalance();
        }

        // Check for signature
        bytes32 txHash = _transaction.encodeHash();
        //bytes32 convertedHash = MessageHashUtils.toEthSignedMessageHash(txHash);
        address signer = ECDSA.recover(txHash, _transaction.signature);
        bool isValidSigner = signer == owner();
        if(isValidSigner) {
            magic = ACCOUNT_VALIDATION_SUCCESS_MAGIC;
        } else {
            magic = bytes4(0);
        }
        return magic;
    }

    function _executeTransaction (Transaction memory _transaction) internal {
        address to = address(uint160(_transaction.to));  
        uint128 value = Utils.safeCastToU128(_transaction.value);
        bytes memory data = _transaction.data;

        if (to == address(DEPLOYER_SYSTEM_CONTRACT)) {
            uint32 gas = Utils.safeCastToU32(gasleft());
            SystemContractsCaller.systemCallWithPropagatedRevert(gas, to, value, data);
        } else {
            bool success;
            assembly {
                success := call(gas(), to, value, add(data, 0x20), mload(data), 0, 0)
            }
            if (!success) {
                revert ZkMinimalAccount__ExecutionFailed();
            }
        }
    }
}