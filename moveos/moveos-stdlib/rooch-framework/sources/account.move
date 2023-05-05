module rooch_framework::account{
   use std::error;
   use std::bcs;
   use std::hash;
   use std::vector;
   use std::signer;
   use moveos_std::bcd;
   #[test_only]
   use std::debug;

   friend rooch_framework::genesis;
   friend rooch_framework::transaction_validator;

   /// Resource representing an account.
   struct Account has key, store {
      authentication_key: vector<u8>,
      sequence_number: u64,
      //TODO do we need a global unique identifiers?
      //guid_creation_num: u64,
   }

   /// A resource that holds the tokens stored in this account
   struct Balance<phantom TokenType> has key {
      // TODO token standard
   }

   // ResourceAccount can only be stored under address, not in other structs.
   struct ResourceAccount has key {}
   // SignerCapability can only be stored in other structs, not under address.
   // So that the capability is always controlled by contracts, not by some EOA.
   struct SignerCapability has store { addr: address }



   const MAX_U64: u128 = 18446744073709551615;
   const ZERO_AUTH_KEY: vector<u8> = x"0000000000000000000000000000000000000000000000000000000000000000";
   // cannot be dummy key, or empty key
   const CONTRACT_ACCOUNT_AUTH_KEY_PLACEHOLDER:vector<u8> = x"0000000000000000000000000000000000000000000000000000000000000001";

   /// Scheme identifier for Ed25519 signatures used to derive authentication keys for Ed25519 public keys.
   const ED25519_SCHEME: u8 = 0;
   /// Scheme identifier for MultiEd25519 signatures used to derive authentication keys for MultiEd25519 public keys.
   const MULTI_ED25519_SCHEME: u8 = 1;
   /// Scheme identifier used when hashing an account's address together with a seed to derive the address (not the
   /// authentication key) of a resource account. This is an abuse of the notion of a scheme identifier which, for now,
   /// serves to domain separate hashes used to derive resource account addresses from hashes used to derive
   /// authentication keys. Without such separation, an adversary could create (and get a signer for) a resource account
   /// whose address matches an existing address of a MultiEd25519 wallet.
   const DERIVE_RESOURCE_ACCOUNT_SCHEME: u8 = 255;
   /// authentication key length
   const AUTHENTICATION_KEY_LENGTH: u64 = 32;




   /// Account already exists
   const EAccountAlreadyExists: u64 = 1;
   /// Account does not exist
   const EAccountNotExist: u64 = 2;
   /// Sequence number exceeds the maximum value for a u64
   const ESequenceNumberTooBig: u64 = 3;
   /// The provided authentication key has an invalid length
   const EMalformedAuthenticationKey: u64 = 4;
   /// Cannot create account because address is reserved
   const EAddressReseved: u64 = 5;
   /// An attempt to create a resource account on an account that has a committed transaction
   const EResourceAccountAlreadyUsed: u64 = 6;
   /// Resource Account can't derive resource account
   const EAccountIsAlreadyResourceAccount: u64 = 7;
   /// Address to create is not a valid reserved address for Rooch framework
   const ENoValidFrameworkReservedAddress: u64 = 11;





   /// TODO should provide a entry function at this module
   /// How to provide account extension?
   public entry fun create_account_entry(auth_key: address): signer{
      Self::create_account(auth_key)
   }

   /// Publishes a new `Account` resource under `new_address`. A signer representing `new_address`
   /// is returned. This way, the caller of this function can publish additional resources under
   /// `new_address`.
   public(friend) fun create_account(new_address: address): signer {
      assert!(
         new_address != @vm_reserved && new_address != @rooch_framework,
         error::invalid_argument(EAddressReseved)
      );

      // there cannot be an Account resource under new_addr already.
      assert!(!exists<Account>(new_address), error::already_exists(EAccountAlreadyExists));      

      create_account_unchecked(new_address)
   }

   fun create_account_unchecked(new_address: address): signer {
      let new_account = create_signer(new_address);
      let authentication_key = bcs::to_bytes(&new_address);
      assert!(
         vector::length(&authentication_key) == AUTHENTICATION_KEY_LENGTH,
         error::invalid_argument(EMalformedAuthenticationKey)
      );

      // TODO event register
      move_to(
         &new_account,
         Account {
            authentication_key,
            sequence_number: 0,
         }
      );

      new_account
   }

   /// create the account for system reserved addresses
   public(friend) fun create_framework_reserved_account(addr: address): (signer, SignerCapability) {
      assert!(
         addr == @0x1 ||
             addr == @0x2 ||
             addr == @0x3 ||
             addr == @0x4 ||
             addr == @0x5 ||
             addr == @0x6 ||
             addr == @0x7 ||
             addr == @0x8 ||
             addr == @0x9 ||
             addr == @0xa,
         error::permission_denied(ENoValidFrameworkReservedAddress),
      );
      let signer = create_account_unchecked(addr);
      let signer_cap = SignerCapability { addr };
      (signer, signer_cap)
   }


   /// Return the current sequence number at `addr`
   public fun sequence_number(addr: address): u64 acquires Account {
      sequence_number_for_account(borrow_global<Account>(addr))
   }

   public(friend) fun increment_sequence_number(addr: address) acquires Account {
      let sequence_number = &mut borrow_global_mut<Account>(addr).sequence_number;

      assert!(
         (*sequence_number as u128) < MAX_U64,
         error::out_of_range(ESequenceNumberTooBig)
      );

      *sequence_number = *sequence_number + 1;
   }

   /// Helper to return the sequence number field for given `account`
   fun sequence_number_for_account(account: &Account): u64 {
      account.sequence_number
   }

   /// Return the current TokenType balance of the account at `addr`.
   public fun balance<TokenType: store>(_addr: address): u128 {
      //TODO token standard, with balance precesion(u64|u128|u256)
      0u128
   }

   #[view]
   public fun get_authentication_key(addr: address): vector<u8> acquires Account {
      *&borrow_global<Account>(addr).authentication_key
   }

   public fun signer_address(cap: &SignerCapability): address {
      cap.addr
   }

   public fun is_resource_account(addr: address): bool {
      exists<ResourceAccount>(addr)
   }


   #[view]
   public fun exists_at(addr: address): bool {
      exists<Account>(addr)
   }


   native fun create_signer(addr: address): signer;


   /// A resource account is used to manage resources independent of an account managed by a user.
   /// In Rooch a resource account is created based upon the sha3 256 of the source's address and additional seed data.
   /// A resource account can only be created once
   public fun create_resource_account(source: &signer): (signer, SignerCapability) acquires Account {
      let source_addr = signer::address_of(source);
      let seed = generate_seed_bytes(&source_addr);
      let resource_addr = create_resource_address(&source_addr, seed);
      assert!(!is_resource_account(resource_addr), error::invalid_state(EAccountIsAlreadyResourceAccount));
      let resource_signer = if (exists_at(resource_addr)) {
         let account = borrow_global<Account>(resource_addr);
         assert!(account.sequence_number == 0, error::invalid_state(EResourceAccountAlreadyUsed));
         create_signer(resource_addr)
      } else {
         create_account_unchecked(resource_addr)
      };

      // By default, only the SignerCapability should have control over the resource account and not the auth key.
      // If the source account wants direct control via auth key, they would need to explicitly rotate the auth key
      // of the resource account using the SignerCapability.
      rotate_authentication_key_internal(&resource_signer, ZERO_AUTH_KEY);
      move_to(&resource_signer, ResourceAccount {});

      let signer_cap = SignerCapability { addr: resource_addr };
      (resource_signer, signer_cap)
   }

   /// This is a helper function to generate seed for resource address
   fun generate_seed_bytes(addr: &address): vector<u8> acquires Account{
      let sequence_number = Self::sequence_number(*addr);
      // use rooch token balance as part of seed, just for new address more random.
      // TODO token standar
      // let balance = Self::balance<...>(*addr);

      let seed_bytes = bcs::to_bytes(addr);
      vector::append(&mut seed_bytes, bcs::to_bytes(&sequence_number));
      // vector::append(&mut seed_bytes, bcs::to_bytes(&balance));

      hash::sha3_256(seed_bytes)
   }

   /// This is a helper function to compute resource addresses. Computation of the address
   /// involves the use of a cryptographic hash operation and should be use thoughtfully.
   public fun create_resource_address(source: &address, seed: vector<u8>): address {
      let bytes = bcs::to_bytes(source);
      vector::append(&mut bytes, seed);
      vector::push_back(&mut bytes, DERIVE_RESOURCE_ACCOUNT_SCHEME);
      bcd::to_address(hash::sha3_256(bytes))
   }

   /// This function is used to rotate a resource account's authentication key to 0, so that no private key can control
   /// the resource account.
   public(friend) fun rotate_authentication_key_internal(account: &signer, new_auth_key: vector<u8>) acquires Account {
      let addr = signer::address_of(account);
      assert!(exists_at(addr), error::not_found(EAccountNotExist));
      assert!(
         vector::length(&new_auth_key) == AUTHENTICATION_KEY_LENGTH,
         error::invalid_argument(EMalformedAuthenticationKey)
      );
      let account_resource = borrow_global_mut<Account>(addr);
      account_resource.authentication_key = new_auth_key;
   }

   public fun create_signer_with_capability(capability: &SignerCapability): signer {
      let addr = &capability.addr;
      create_signer(*addr)
   }

   public fun get_signer_capability_address(capability: &SignerCapability): address {
      capability.addr
   }

   #[test_only]
   /// Create signer for testing, independently of an Rooch-style `Account`.
   public fun create_signer_for_test(addr: address): signer { create_signer(addr) }

   #[test_only]
   public fun create_account_for_test(new_address: address): signer {
      create_account_unchecked(new_address)
   }

   #[test]
   /// Assert correct signer creation.
   fun test_create_signer_for_test() {
      assert!(signer::address_of(&create_signer_for_test(@rooch_framework)) == @0x1, 100);
      assert!(signer::address_of(&create_signer_for_test(@0x123)) == @0x123, 101);
   }

   #[test]
   /// Assert correct account creation.
   fun test_create_account_for_test() acquires Account {
      let alice_addr = @123456;
      let alice = create_account_for_test(alice_addr);
      let alice_addr_actual = signer::address_of(&alice);
      let sequence_number = sequence_number(alice_addr);
      debug::print(&get_authentication_key(alice_addr));
      debug::print(&sequence_number);
      assert!(alice_addr_actual == alice_addr, 103);
      assert!(sequence_number >= 0, 104);
   }

   #[test_only]
   struct CapResponsbility has key {
      cap: SignerCapability
   }

   #[test]
   fun test_create_resource_account() acquires Account {
      let alice_addr = @123456;
      let alice = create_account_for_test(alice_addr);
      let (resource_account, resource_account_cap) = create_resource_account(&alice);
      let signer_cap_addr = get_signer_capability_address(&resource_account_cap);
      move_to(&resource_account, CapResponsbility {
         cap: resource_account_cap
      });

      let resource_addr = signer::address_of(&resource_account);
      debug::print(&100100);
      debug::print(&resource_addr);
      assert!(resource_addr != signer::address_of(&alice), 106);
      assert!(resource_addr == signer_cap_addr, 107);
   }
}