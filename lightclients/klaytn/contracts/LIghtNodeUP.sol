// SPDX-License-Identifier: MIT

pragma solidity 0.8.12;

import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./lib/MPT.sol";
import "./lib/RLPReader.sol";
import "./lib/RLPEncode.sol";
import "./interface/ILightNode.sol";
import "./interface/IMPTVerify.sol";

contract LightNodeUP is UUPSUpgradeable, Initializable, ILightNode, Ownable2Step {
    using RLPReader for bytes;
    using RLPReader for uint256;
    using RLPReader for RLPReader.RLPItem;
    using RLPReader for RLPReader.Iterator;
    using MPT for MPT.MerkleProof;

    uint8   constant MSG_COMMIT = 2;
    uint256 constant MAX_VALIDATORS_SIZE = 2160;
    uint256 constant CHANGE_VALIDATORS_SIZE = 3600;
    uint256 constant RLP_INDEX = 3;
    uint256 constant EXTRA_VANITY = 32;

    address public mptVerify;
    uint256 public headerHeight;
    uint256 public validatorIdx;
    uint256 public startHeight;
    Validator[MAX_VALIDATORS_SIZE] public validators;

    struct Validator {
        address[] validators;
        uint256 headerHeight;
    }

    bytes32 constant ADD_VALIDATOR = 0x22206f4a2ac5feb779f2fe7e2130ba563547dd3de6a4160bfcf3bd9cc64c82ee;
    bytes32 constant REMOVE_VALIDATOR = 0x3e9698b37f61d5135393cc4891dd22b1a42d2d350e5d561bcd6967bf75589818;

    mapping(uint256 => Validator) public extendValidator;
    mapping(uint256 => uint256) public extendList;
    uint256 public tempBlockHeight;

    function initialize(
        address[] memory _validators,
        uint256 _headerHeight,
        address _mptVerify
    )
    external
    override
    initializer
    checkAddress(_mptVerify)
    checkMultipleAddress(_validators)
    {
        Validator memory _validator = Validator({
        validators : _validators,
        headerHeight : _headerHeight
        });
        headerHeight = _headerHeight;
        validatorIdx = _getValidatorIndex(headerHeight);
        validators[validatorIdx] = _validator;
        startHeight = _headerHeight;

        mptVerify = _mptVerify;

        _transferOwnership(tx.origin);
    }


    modifier checkAddress(address _address){
        require(_address != address(0), "address is zero");
        _;
    }

    modifier checkMultipleAddress(address[] memory _addressArray){
        for (uint i = 0; i < _addressArray.length; i++) {
            require(_addressArray[i] != address(0), "address have zero");
        }
        _;
    }


    function verifyProofData(bytes memory _receiptProof)
    external
    view
    override
    returns (bool success,
        string memory message,
        bytes memory logs)
    {
        ReceiptProof memory receiptProof = abi.decode(_receiptProof, (ReceiptProof));

        if (receiptProof.deriveSha == DeriveShaOriginal.DeriveShaConcat){
            ReceiptProofConcat memory proof = abi.decode(receiptProof.proof,(ReceiptProofConcat));
            BlockHeader memory header = proof.header;
            (success, ) = checkBlockHeader(header,true);
            if(!success){
                message = "DeriveShaConcat header verify failed";
                return(success,message,logs);
            }
            success = _checkReceiptsConcat(proof.receipts, (bytes32)(header.receiptsRoot));
            if (success) {
                bytes memory bytesReceipt = proof.receipts[proof.logIndex];
                RLPReader.RLPItem memory logsItem = bytesReceipt.toRlpItem().safeGetItemByIndex(RLP_INDEX);
                logs = RLPReader.toRlpBytes(logsItem);
                message = "DeriveShaConcat mpt verify success";
                return(success,message,logs);
            }else{
                message = "DeriveShaConcat mpt verify failed";
                return(success,message,logs);
            }
        } else if (receiptProof.deriveSha == DeriveShaOriginal.DeriveShaOriginal) {
            ReceiptProofOriginal memory proof = abi.decode(receiptProof.proof,(ReceiptProofOriginal));
            (success, ) = checkBlockHeader(proof.header,true);
            if(!success){
                message = "DeriveShaOriginal header verify failed";
                return(success,message,logs);
            }
            (success,logs) = _checkReceiptsOriginal(proof);
            if (success) {
                message = "DeriveShaOriginal mpt verify success";
                return(success,message,logs);
            }else{
                message = "DeriveShaOriginal mpt verify failed";
                return(success,message,logs);
            }
        }else{
            message = "mpt verify failed";
            success = false;
            return(success,message,logs);
        }
    }

    function updateBlockHeader(bytes memory _blockHeaders)
    external
    override
    {
        BlockHeader[] memory _headers = abi.decode(
            _blockHeaders, (BlockHeader[]));

        require(_headers[0].number > headerHeight, "height error");
        if(_headers[0].number % CHANGE_VALIDATORS_SIZE > 0) {

            updateBlockHeaderChange(_headers);
        }else{

            for (uint256 i = 0; i < _headers.length; i++) {
                require(_headers[i].number == headerHeight + CHANGE_VALIDATORS_SIZE, "height epoch error");
                BlockHeader memory bh = _headers[i];
                (bool success, ExtraData memory data) = checkBlockHeader(bh, false);
                require(success, "header verify fail");

                validatorIdx = _getValidatorIndex(bh.number);
                Validator memory tempValidators = validators[validatorIdx];

                while(extendList[tempValidators.headerHeight] > 0){
                    uint256 tempHeight = getRemoveExtendHeight(tempValidators.headerHeight);
                    uint256 trueHeight = getTrueHeight(tempValidators.headerHeight,tempHeight);
                    delete extendValidator[tempHeight];
                    delete extendList[trueHeight];
                }
                Validator memory v = Validator({
                validators : data.validators,
                headerHeight : bh.number
                });
                validators[validatorIdx] = v;
                headerHeight = bh.number;
            }
        }

    }

    function updateBlockHeaderChange(BlockHeader[] memory _blockHeaders)
    public
    {
        BlockHeader memory header0 = _blockHeaders[0];
        BlockHeader memory header1 = _blockHeaders[1];
        require(header0.voteData.length > 0,"The extension update is not satisfied");
        require(header0.number + 1 == header1.number, "Synchronous height error");

        (bool success, ExtraData memory header1Extra) = checkBlockHeader(header1, true);
        (bool hearderTag0, ExtraData memory header0Extra) = checkBlockHeader(header0, true);
        require(success, "header change verify fail");

        Vote memory vote = decodeVote(_blockHeaders[0].voteData);
        bool success0;
        bool success1;
        if(keccak256(vote.key) == ADD_VALIDATOR){
            success0  = _checkCommittedAddress(header0Extra.validators,vote.value);
            success1  = _checkCommittedAddress(header1Extra.validators,vote.value);
            require(!success0 && success1,"ADD_VALIDATOR error");
        }else if (keccak256(vote.key) == REMOVE_VALIDATOR){
            success0  = _checkCommittedAddress(header0Extra.validators,vote.value);
            success1  = _checkCommittedAddress(header1Extra.validators,vote.value);
            require(success0 && !success1 ,"REMOVE_VALIDATOR error");
        }

        Validator memory v = Validator({
        validators : header1Extra.validators,
        headerHeight : header1.number
        });
        extendValidator[header1.number] = v;
        startHeight = getBlockHeightList(header1.number,true);
        extendList[startHeight] = header1.number;
        tempBlockHeight = header1.number;
    }

    function getBlockHeightList(uint256 _height,bool _tag) public view returns(uint256 truetHeight){
        uint256 opochBlockHeight = (_height / CHANGE_VALIDATORS_SIZE) * CHANGE_VALIDATORS_SIZE;
        if(extendList[opochBlockHeight] > 0){
            if(!_tag) {
                _height = _height + CHANGE_VALIDATORS_SIZE;
            }
            if(_height >= tempBlockHeight){
                truetHeight = tempBlockHeight;
            }else{
                truetHeight = getTrueHeight(opochBlockHeight,_height);
            }
        }else{
            truetHeight = opochBlockHeight;
        }
    }

    function getTrueHeight(uint256 _height,uint256 _verifyHeight) public view returns(uint256){
        if(extendList[_height] >= _verifyHeight){
            return _height;
        }else {
           return getTrueHeight(extendList[_height],_verifyHeight);
        }
    }

    function getRemoveExtendHeight(uint256 _height) public view returns(uint256){
        if(extendList[_height] == 0){
            return _height;
        }else{
            return getRemoveExtendHeight(extendList[_height]);
        }
    }

    function decodeVote(bytes memory _votes) public view returns(Vote memory votes){
        RLPReader.RLPItem[] memory ls = _votes.toRlpItem().toList();

        bytes memory _seal = ls[1].toBytes();

        return ( Vote({
        validator : ls[0].toAddress(),
        key : ls[1].toBytes(),
        value : ls[2].toAddress()
        }));
    }

    function verifiableHeaderRange()
    external
    override
    view
    returns (uint256 start, uint256 end){
        return (_getStartValidatorHeight(), _getEndValidatorHeight());
    }


    function getBytes(ReceiptProofOriginal memory _proof)
    external
    pure
    returns (bytes memory)
    {
        bytes memory proof = abi.encode(_proof);

        ReceiptProof memory receiptProof = ReceiptProof(proof,DeriveShaOriginal.DeriveShaOriginal);

        return abi.encode(receiptProof);
    }

    function getHeadersBytes(BlockHeader[] memory _blockHeaders)
    external
    pure
    returns (bytes memory)
    {
        return abi.encode(_blockHeaders);
    }

    function getHeadersArray(bytes memory _blockHeaders)
    external
    pure
    returns (BlockHeader[] memory)
    {
        BlockHeader[] memory _headers = abi.decode(
            _blockHeaders, (BlockHeader[]));
        return _headers;
    }

    function decodeVerifyProofData(bytes memory _receiptProof)
    external
    pure
    returns (ReceiptProof memory proof){
        proof = abi.decode(_receiptProof, (ReceiptProof));
    }

    function _checkReceiptsConcat(bytes[] memory _receipts, bytes32 _receiptsHash)
    internal
    pure
    returns (bool){
        bytes memory receiptsAll;
        for (uint i = 0; i < _receipts.length; i++) {
            receiptsAll = bytes.concat(receiptsAll, _receipts[i]);
        }
        return keccak256(receiptsAll) == _receiptsHash;
    }

    function _checkReceiptsOriginal(ReceiptProofOriginal memory _proof)
    internal
    view
    returns (bool success,bytes memory logs){

        bytes memory bytesReceipt = _encodeReceipt(_proof.txReceipt);

        success = IMPTVerify(mptVerify).verifyTrieProof(
            bytes32(_proof.header.receiptsRoot),
            _proof.keyIndex,
            _proof.proof,
            bytesReceipt
        );
        uint256 rlpIndex = 3;
        logs = bytesReceipt.toRlpItem().toList()[rlpIndex].toRlpBytes();

        return (success,logs);
    }


    function checkBlockHeader(BlockHeader memory header,bool tag)
    internal
    view
    returns (bool, ExtraData memory)
    {

        bool success = _checkHeaderParam(header);

        require(success, "header param error");

        (bytes memory extHead, ExtraData memory ext) = decodeHeaderExtraData(header.extraData);
        (bytes memory extraNoSeal, bytes memory seal) = _getRemoveSealExtraData(ext, extHead, false);
        bytes32 signerHash = _getBlockNewHash(header, extraNoSeal);

        address signer = _recoverSigner(seal, keccak256(abi.encodePacked(signerHash)));

        uint num = header.number;

        if(!tag){
            num = header.number - CHANGE_VALIDATORS_SIZE;
        }

        Validator memory v = _getCanVerifyValidator(num,tag);

        require(v.headerHeight > 0, "validator load fail");

        require(v.headerHeight + CHANGE_VALIDATORS_SIZE >= header.number, "check block height error");


        success = _checkCommittedAddress(v.validators, signer);

        require(success, "signer fail");

        (bytes memory extra,) = _getRemoveSealExtraData(ext, extHead, true);

        bytes32 hash = _getBlockNewHash(header, extra);

        bytes memory committedMsg = abi.encodePacked(hash, MSG_COMMIT);

        return (_checkCommitSeal(v, committedMsg, ext.committedSeal), ext);
    }

    function decodeHeaderExtraData(bytes memory _extBytes)
    public
    pure
    returns (
        bytes memory extTop,
        ExtraData memory extData)
    {
        (bytes memory extraHead,bytes memory istBytes) = _splitExtra(_extBytes);

        RLPReader.RLPItem[] memory ls = istBytes.toRlpItem().toList();
        RLPReader.RLPItem[] memory itemValidators = ls[0].toList();
        RLPReader.RLPItem[] memory itemCommittedSeal = ls[2].toList();

        bytes memory _seal = ls[1].toBytes();
        address[] memory _validators = new address[](itemValidators.length);
        for (uint256 i = 0; i < itemValidators.length; i++) {
            _validators[i] = itemValidators[i].toAddress();
        }
        bytes[] memory _committedSeal = new bytes[](itemCommittedSeal.length);
        for (uint256 i = 0; i < itemCommittedSeal.length; i++) {
            _committedSeal[i] = itemCommittedSeal[i].toBytes();
        }

        return (extraHead, ExtraData({
        validators : _validators,
        seal : _seal,
        committedSeal : _committedSeal
        }));
    }

    function _checkHeaderParam(BlockHeader memory header)
    internal
    view
    returns (bool)
    {
        if (header.timestamp + 60 > block.timestamp) {return false;}
        if (header.blockScore == 0) {return false;}
        return true;
    }


    function _getEndValidatorHeight()
    internal
    view
    returns (uint256)
    {
        Validator memory v = validators[validatorIdx];
        return (v.headerHeight / CHANGE_VALIDATORS_SIZE + 1) * CHANGE_VALIDATORS_SIZE;
    }

    function _getStartValidatorHeight()
    internal
    view
    returns (uint256)
    {
        uint idx = validatorIdx;
        uint start = validators[idx].headerHeight;
        for (uint i = 0; i < MAX_VALIDATORS_SIZE; i++) {
            if (idx == 0) {
                idx = MAX_VALIDATORS_SIZE - 1;
            } else {
                idx --;
            }
            Validator memory v = validators[idx];
            if (v.headerHeight != 0 && v.headerHeight < start) {
                start = v.headerHeight;
            } else {
                break;
            }
        }
        return start;

    }

    function _getValidatorIndex(uint _startHeight)
    internal
    pure
    returns (uint)
    {
        return (_startHeight / CHANGE_VALIDATORS_SIZE) % MAX_VALIDATORS_SIZE;
    }


    function _getNextValidatorIndex() internal view returns (uint){
        if (validatorIdx == MAX_VALIDATORS_SIZE - 1) {
            return 0;
        }
        return validatorIdx + 1;
    }


    function _splitExtra(bytes memory _extra)
    internal
    pure
    returns (
        bytes memory extraHead,
        bytes memory extraEnd)
    {
        require(_extra.length >= 32, "Invalid extra result type");
        extraEnd = new bytes(_extra.length - EXTRA_VANITY);
        extraHead = new bytes(EXTRA_VANITY);
        for (uint256 i = 0; i < _extra.length; i++) {
            if (i < EXTRA_VANITY) {
                extraHead[i] = _extra[i];
            } else {
                extraEnd[i - EXTRA_VANITY] = _extra[i];
            }
        }
        return (extraHead, extraEnd);
    }

    function _getRemoveSealExtraData(
        ExtraData memory _ext,
        bytes memory _extHead,
        bool _keepSeal)
    internal
    pure
    returns (
        bytes memory,
        bytes memory)
    {
        bytes[] memory listExt = new bytes[](3);
        bytes[] memory listValidators = new bytes[](_ext.validators.length);

        for (uint i = 0; i < _ext.validators.length; i ++) {
            listValidators[i] = RLPEncode.encodeAddress(_ext.validators[i]);
        }
        listExt[0] = RLPEncode.encodeList(listValidators);
        if (!_keepSeal) {
            listExt[1] = RLPEncode.encodeBytes("");
        } else {
            listExt[1] = RLPEncode.encodeBytes(_ext.seal);
        }
        listExt[2] = RLPEncode.encodeList(new bytes[](0));

        bytes memory output = RLPEncode.encodeList(listExt);
        _extHead[31] = 0;
        return (abi.encodePacked(_extHead, output), _ext.seal);
    }

    function _splitSignature(bytes memory _sig)
    internal
    pure
    returns (bytes32 r, bytes32 s, uint8 v)
    {
        require(_sig.length == 65, "invalid signature length");
        assembly {
            r := mload(add(_sig, 32))
            s := mload(add(_sig, 64))
            v := byte(0, mload(add(_sig, 96)))
        }
    }

    function _recoverSigner(bytes memory seal, bytes32 hash)
    internal
    pure
    returns (address)
    {
        (bytes32 r, bytes32 s, uint8 v) = _splitSignature(seal);
        if (v <= 1) {
            v = v + 27;
        }
        return ECDSA.recover(hash, v, r, s);
    }

    function _getBlockNewHash(BlockHeader memory header, bytes memory extraData)
    internal
    pure
    returns (bytes32)
    {
        bytes[] memory list = new bytes[](15);
        list[0] = RLPEncode.encodeBytes(header.parentHash);
        list[1] = RLPEncode.encodeAddress(header.reward);
        list[2] = RLPEncode.encodeBytes(header.stateRoot);
        list[3] = RLPEncode.encodeBytes(header.transactionsRoot);
        list[4] = RLPEncode.encodeBytes(header.receiptsRoot);
        list[5] = RLPEncode.encodeBytes(header.logsBloom);
        list[6] = RLPEncode.encodeUint(header.blockScore);
        list[7] = RLPEncode.encodeUint(header.number);
        list[8] = RLPEncode.encodeUint(header.gasUsed);
        list[9] = RLPEncode.encodeUint(header.timestamp);
        list[10] = RLPEncode.encodeUint(header.timestampFoS);
        list[11] = RLPEncode.encodeBytes(extraData);
        list[12] = RLPEncode.encodeBytes(header.governanceData);
        list[13] = RLPEncode.encodeBytes(header.voteData);
        list[14] = RLPEncode.encodeUint(header.baseFee);
        return keccak256(RLPEncode.encodeList(list));
    }


    function _getCanVerifyValidator(uint256 _height,bool _tag)
    public
    view
    returns (Validator memory v)
    {
        uint256 opochBlockHeight = ((_height / CHANGE_VALIDATORS_SIZE)) * CHANGE_VALIDATORS_SIZE;
        if(extendList[opochBlockHeight] > 0){
            uint256 verifyHeight = getBlockHeightList(_height,_tag);
            if(opochBlockHeight == verifyHeight){
                uint256 idx = _getValidatorIndex(_height);
                v = validators[idx];
                return v;
            }else {
                return extendValidator[verifyHeight];
            }
        }else{
            uint256 idx = _getValidatorIndex(_height);
            v = validators[idx];
            return v;
        }
    }


    function _checkCommittedAddress(
        address[] memory _validators,
        address _address)
    internal
    pure
    returns (bool)
    {
        for (uint i = 0; i < _validators.length; i++) {
            if (_validators[i] == _address) return true;
        }
        return false;
    }

    function _isRepeat(
        address[] memory _miners,
        address _miner,
        uint256 _limit)
    internal
    pure
    returns (bool) {
        for (uint256 i = 0; i < _limit; i++) {
            if (_miners[i] == _miner) {
                return true;
            }
        }

        return false;
    }



    /**
     * @dev Calculate the number of faulty nodes.
     * https://github.com/klaytn/klaytn/blob/841a8ad3b45e92f4ea378c1ee1f06cdb963afbac/consensus/istanbul/validator/default.go#L370
     *
     */
    function _getFaultyNodeNumber(uint256 _n) internal pure returns(uint256){
        if(_n % 3 == 0){
            return _n / 3 - 1;
        }else{
            return _n / 3;
        }
    }


    /**
     * @dev Check whether the CommitSeal is adequate.
     * https://github.com/klaytn/klaytn/blob/841a8ad3b45e92f4ea378c1ee1f06cdb963afbac/consensus/istanbul/backend/engine.go#L359
     *
     */
    function _checkCommitSeal(
        Validator memory v,
        bytes memory committedMsg,
        bytes[] memory committedSeal)
    internal
    pure
    returns (bool)
    {
        bytes32 msgHash = keccak256(committedMsg);
        address[] memory miners = new address[](v.validators.length);

        uint checkedCommittee = 0;
        for (uint i = 0; i < committedSeal.length; i++) {
            address committee = _recoverSigner(committedSeal[i], msgHash);
            if (_checkCommittedAddress(v.validators,committee) && !_isRepeat(miners,committee,i)) {
                checkedCommittee++;
            }
            miners[i] = committee;
        }
        return checkedCommittee > (_getFaultyNodeNumber(v.validators.length)) * 2;
    }


    function _getBytesSlice(bytes memory b, uint256 start, uint256 length)
    internal
    pure
    returns (bytes memory)
    {
        bytes memory out = new bytes(length);

        for (uint256 i = 0; i < length; i++) {
            out[i] = b[start + i];
        }

        return out;
    }

    function _encodeReceipt(TxReceipt memory _txReceipt)
    internal
    pure
    returns (bytes memory output)
    {
        bytes[] memory list = new bytes[](4);
        list[0] = RLPEncode.encodeBytes(_txReceipt.postStateOrStatus);
        list[1] = RLPEncode.encodeUint(_txReceipt.cumulativeGasUsed);
        list[2] = RLPEncode.encodeBytes(_txReceipt.bloom);
        bytes[] memory listLog = new bytes[](_txReceipt.logs.length);
        bytes[] memory loglist = new bytes[](3);
        for (uint256 j = 0; j < _txReceipt.logs.length; j++) {
            loglist[0] = RLPEncode.encodeAddress(_txReceipt.logs[j].addr);
            bytes[] memory loglist1 = new bytes[](
                _txReceipt.logs[j].topics.length
            );
            for (uint256 i = 0; i < _txReceipt.logs[j].topics.length; i++) {
                loglist1[i] = RLPEncode.encodeBytes(
                    _txReceipt.logs[j].topics[i]
                );
            }
            loglist[1] = RLPEncode.encodeList(loglist1);
            loglist[2] = RLPEncode.encodeBytes(_txReceipt.logs[j].data);
            bytes memory logBytes = RLPEncode.encodeList(loglist);
            listLog[j] = logBytes;
        }
        list[3] = RLPEncode.encodeList(listLog);
        output = RLPEncode.encodeList(list);
    }

    function _transferOwnership(address newOwner) internal virtual override {
        super._transferOwnership(newOwner);
        _changeAdmin(newOwner);
    }


    /** UUPS *********************************************************/
    function _authorizeUpgrade(address)
    internal
    view
    onlyOwner
    override {}

    function getAdmin() external view returns (address){
        return _getAdmin();
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

}