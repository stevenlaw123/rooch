/// This module implements Ethereum validator with the ECDSA recoverable signature over Secp256k1 crypto scheme.
module rooch_framework::ethereum_validator {

    use std::error;
    use std::vector;
    use std::option::{Self, Option};
    use std::signer;
    use moveos_std::storage_context::{Self, StorageContext};
    use rooch_framework::account_authentication;
    use rooch_framework::hash;
    use rooch_framework::ecdsa_k1_recoverable;
    use rooch_framework::auth_validator;

    /// error code
    const EInvalidPublicKeyLength: u64 = 0;

    struct EthereumValidator has store, drop {}

    public entry fun rotate_authentication_key_entry<T>(
        ctx: &mut StorageContext,
        account: &signer,
        public_key: vector<u8>
    ) {
        // compare newly passed public key with Ethereum public key length to ensure it's compatible
        assert!(
            vector::length(&public_key) == ecdsa_k1_recoverable::public_key_length(),
            error::invalid_argument(EInvalidPublicKeyLength)
        );

        // User can rotate the authentication key arbitrarily, so we do not need to check the new public key with the account address.
        let authentication_key = public_key_to_authentication_key(public_key);
        let account_addr = signer::address_of(account);
        rotate_authentication_key(ctx, account_addr, authentication_key);
    }

    fun rotate_authentication_key(ctx: &mut StorageContext, account_addr: address, authentication_key: vector<u8>) {
        account_authentication::rotate_authentication_key<EthereumValidator>(ctx, account_addr, authentication_key);
    }

    public entry fun remove_authentication_key_entry<T>(ctx: &mut StorageContext, account: &signer) {
        account_authentication::remove_authentication_key<EthereumValidator>(ctx, signer::address_of(account));
    }

    /// Get the authentication key of the given authenticator from authenticator_payload.
    public fun get_authentication_key_from_authenticator_payload(authenticator_payload: &vector<u8>): vector<u8> {
        let public_key = ecdsa_k1_recoverable::get_public_key_from_authenticator_payload(authenticator_payload);
        let addr = public_key_to_address(public_key);
        moveos_std::bcs::to_bytes(&addr)
    }

    /// TODO: https://github.com/rooch-network/rooch/issues/615
    public fun public_key_to_address(public_key: vector<u8>): address {
        moveos_std::bcs::to_address(public_key_to_authentication_key(public_key))
    }

    /// Get the authentication key of the given public key.
    public fun public_key_to_authentication_key(public_key: vector<u8>): vector<u8> {
        let bytes = vector::singleton((ecdsa_k1_recoverable::scheme() as u8));
        vector::append(&mut bytes, public_key);
        hash::blake2b256(&bytes)
    }

    /// Get the authentication key option of the given account.
    public fun get_authentication_key_option_from_account(ctx: &StorageContext, addr: address): Option<vector<u8>> {
        account_authentication::get_authentication_key<EthereumValidator>(ctx, addr)
    }

    /// The authentication key exists in account or not.
    public fun is_authentication_key_in_account(ctx: &StorageContext, addr: address): bool {
        option::is_some(&get_authentication_key_option_from_account(ctx, addr))
    }

    /// Extract the authentication key of the authentication key option.
    public fun get_authentication_key_from_account(ctx: &StorageContext, addr: address): vector<u8> {
        option::extract(&mut get_authentication_key_option_from_account(ctx, addr))
    }

    /// Only validate the authenticator's signature.
    public fun validate_signature(authenticator_payload: &vector<u8>, tx_hash: &vector<u8>) {
        assert!(
            ecdsa_k1_recoverable::verify(
                &ecdsa_k1_recoverable::get_signature_from_authenticator_payload(authenticator_payload),
                tx_hash,
                ecdsa_k1_recoverable::keccak256()
            ),
            auth_validator::error_invalid_authenticator()
        );
    }

    public fun validate(ctx: &StorageContext, authenticator_payload: vector<u8>) {
        let tx_hash = storage_context::tx_hash(ctx);
        validate_signature(&authenticator_payload, &tx_hash);

        // TODO compare the auth_key from the payload with the auth_key from the account
    }

    fun pre_execute(
        _ctx: &mut StorageContext,
    ) {}

    fun post_execute(
        ctx: &mut StorageContext,
    ) {
        let account_addr = storage_context::sender(ctx);
        if (is_authentication_key_in_account(ctx, account_addr)) {
            let auth_key_in_account = get_authentication_key_from_account(ctx, account_addr);
            std::debug::print(&auth_key_in_account);
        }
    }

    // this test ensures that the Ethereum public_key_to_address function is compatible with the one in the rust code
    #[test]
    fun test_public_key_to_address() {
        let public_key = x"031b84c5567b126440995d3ed5aaba0565d71e1834604819ff9c17f5e9d5dd078f";
        let addr = public_key_to_address(public_key);
        assert!(addr == @0x8c891976da9498ec1d3ff778a5d6c40c217d63cc8c48539c959f8b683eedf5a4, 1000);
    }
}