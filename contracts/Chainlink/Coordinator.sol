pragma solidity 0.5.0;

import "../zeppelin/math/SafeMath.sol";
import "./interfaces/ChainlinkRequestInterface.sol";
import "./interfaces/CoordinatorInterface.sol";
import "./interfaces/LinkTokenInterface.sol";

// Coordinator handles oracle service aggreements between one or more oracles.
contract Coordinator is ChainlinkRequestInterface, CoordinatorInterface {
  using SafeMath for uint256;

  LinkTokenInterface internal LINK;

  struct ServiceAgreement {
    uint256 payment;
    uint256 expiration;
    uint256 endAt;
    address[] oracles;
    bytes32 requestDigest;
  }

  struct Callback {
    uint256 amount;
    address addr;
    bytes4 functionId;
    uint64 cancelExpiration;
  }

  mapping(bytes32 => Callback) private callbacks;
  mapping(bytes32 => ServiceAgreement) public serviceAgreements;

  constructor(address _link) public {
    LINK = LinkTokenInterface(_link);
  }

  event RunRequest(
    bytes32 indexed sAId,
    address indexed requester,
    uint256 indexed amount,
    uint256 requestId,
    uint256 version,
    bytes data
  );

  event NewServiceAgreement(
    bytes32 indexed said,
    bytes32 indexed requestDigest
  );

  event CancelRequest(
    bytes32 internalId
  );

  function onTokenTransfer(
    address _sender,
    uint256 _amount,
    bytes memory _data
  )
    public
    onlyLINK
    permittedFunctionsForLINK
  {
    assembly {
      // solium-disable-next-line security/no-low-level-calls
      mstore(add(_data, 36), _sender) // ensure correct sender is passed
      // solium-disable-next-line security/no-low-level-calls
      mstore(add(_data, 68), _amount)    // ensure correct amount is passed
    }
    // solium-disable-next-line security/no-low-level-calls
    (bool result,) = address(this).delegatecall(_data); // calls requestData
    require(result, "Unable to create request");
  }

  function requestData(
    address _sender,
    uint256 _amount,
    uint256 _version,
    bytes32 _sAId,
    address _callbackAddress,
    bytes4 _callbackFunctionId,
    uint256 _nonce,
    bytes calldata _data
  )
    external
    onlyLINK
    sufficientLINK(_amount, _sAId)
    checkCallbackAddress(_callbackAddress)
  {
    bytes32 requestId = keccak256(abi.encodePacked(_sender, _nonce));
    require(callbacks[requestId].cancelExpiration == 0, "Must use a unique ID");
    callbacks[requestId] = Callback(
      _amount,
      _callbackAddress,
      _callbackFunctionId,
      uint64(now.add(5 minutes)));
    emit RunRequest(
      _sAId,
      _sender,
      _amount,
      uint256(requestId),
      _version,
      _data);
  }

  // This is mostly useful as a sanity check in the #getId test, because the
  // hash value there is illegible by design.
  function getPackedArguments(
    uint256 _payment,
    uint256 _expiration,
    uint256 _endAt,
    address[] memory _oracles,
    bytes32 _requestDigest
  )
    public
    pure
    returns (bytes memory)
  {
    return abi.encodePacked(_payment, _expiration, _endAt, _oracles, _requestDigest);
  }

  function getId(
    uint256 _payment,
    uint256 _expiration,
    uint256 _endAt,
    address[] memory _oracles,
    bytes32 _requestDigest
  )
    public pure returns (bytes32)
  {
    return keccak256(getPackedArguments(_payment, _expiration, _endAt, _oracles, _requestDigest));
  }

  function initiateServiceAgreement(
    uint256 _payment,
    uint256 _expiration,
    uint256 _endAt,
    address[] calldata _oracles,
    uint8[] calldata _vs,
    bytes32[] calldata _rs,
    bytes32[] calldata _ss,
    bytes32 _requestDigest
  )
    external
    returns (bytes32 serviceAgreementID)
  {
    require(_oracles.length == _vs.length && _vs.length == _rs.length && _rs.length == _ss.length, "Must pass in as many signatures as oracles"); /* solium-disable-line max-len */
    require(_endAt > block.timestamp, "End of ServiceAgreement must be in the future");

    serviceAgreementID = getId(_payment, _expiration, _endAt, _oracles, _requestDigest);

    verifyOracleSignatures(serviceAgreementID, _oracles, _vs, _rs, _ss);

    serviceAgreements[serviceAgreementID] = ServiceAgreement(
      _payment,
      _expiration,
      _endAt,
      _oracles,
      _requestDigest
    );

    emit NewServiceAgreement(serviceAgreementID, _requestDigest);
  }

  function verifyOracleSignatures(
    bytes32 _serviceAgreementID,
    address[] memory _oracles,
    uint8[] memory _vs,
    bytes32[] memory _rs,
    bytes32[] memory _ss
  )
    private pure
  {
    for (uint i = 0; i < _oracles.length; i++) {
      address signer = getOracleAddressFromSASignature(_serviceAgreementID, _vs[i], _rs[i], _ss[i]);
      require(_oracles[i] == signer, "Invalid oracle signature specified in SA");
    }

  }

  function getOracleAddressFromSASignature(
    bytes32 _serviceAgreementID,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  )
    private pure returns (address)
  {
    bytes32 prefixedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", _serviceAgreementID));
    return ecrecover(prefixedHash, _v, _r, _s);
  }

  modifier onlyLINK() {
    require(msg.sender == address(LINK), "Must use LINK token"); 
    _;
  }

  modifier permittedFunctionsForLINK() {
    bytes4[1] memory funcSelector;
    assembly {
      // solium-disable-next-line security/no-low-level-calls
      calldatacopy(funcSelector, 132, 4) // grab function selector from calldata
    }
    require(funcSelector[0] == this.requestData.selector, "Must use whitelisted functions");
    _;
  }

  modifier sufficientLINK(uint256 _amount, bytes32 _sAId) {
    require(_amount >= serviceAgreements[_sAId].payment, "Below agreed payment");
    _;
  }

  modifier isValidRequest(uint256 _requestId) {
    require(callbacks[bytes32(_requestId)].addr != address(0), "Must have a valid requestId");
    _;
  }

  function fulfillData(
    uint256 _requestId,
    bytes32 _data
  )
    external
    isValidRequest(_requestId)
    returns (bool)
  {
    bytes32 requestId = bytes32(_requestId);
    Callback memory callback = callbacks[requestId];
    delete callbacks[requestId];
    // All updates to the oracle's fulfillment should come before calling the
    // callback(addr+functionId) as it is untrusted. See:
    // https://solidity.readthedocs.io/en/develop/security-considerations.html#use-the-checks-effects-interactions-pattern
    (bool response,) = callback.addr.call(abi.encodePacked(callback.functionId, _requestId, _data));
    return response; // solium-disable-line security/no-low-level-calls
  }

  // Necessary to implement ChainlinkRequestInterface
  function cancel(bytes32) external {}

  modifier checkCallbackAddress(address _to) {
    require(_to != address(LINK), "Cannot callback to LINK");
    _;
  }
}
