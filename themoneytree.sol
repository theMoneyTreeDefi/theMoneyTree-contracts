// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@chainlink/contracts/src/v0.8/vrf/VRFV2WrapperConsumerBase.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";



contract MoneyTree is VRFV2WrapperConsumerBase, ReentrancyGuard, Initializable, Ownable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant DIVIDER = 10000;

    enum Group { DEV, POOL_A, POOL_B, POOL_C, LOTTERY, TRADING, TOTAL }

    struct UserInfo {
        Group group;
        bool deposited;
        uint256 totalReceived;
        uint256 availableToClaim;
        uint256 numberOfReferrals;
        uint256 lastEpochAddReferrals;
        bool winner;
    }

    struct GroupInfo {
        uint256 depositSize;
        uint256 maxPayout;
        uint256 distributionPercent;
    }

    struct RequestStatus {
        uint256 paid;
        bool fulfilled;
        uint256[] randomWords;
    }

    struct Values {
        uint256 distributeAmountDev;
        uint256 distributeAmountPoolA;
        uint256 distributeAmountPoolB;
        uint256 distributeAmountPoolC;
        uint256 distributeAmountLottery;
        uint256 distributeAmountTrading;
        uint256 devPaymentAmount;
        address recipient;

        uint256 maxPoolAmountForBonusROI;
        uint256 maxUsersForROIBonus;
        uint256 usersForROIBonus;
        uint256 len;

        uint256 winnerIndex;
        address winnerAddress;
        uint256 winnerPayment;
        bool winnersStayInList;
        uint256 numberOfWinnersStayInList;

        uint256 numberUsersInPool;
        uint256 distributePayment;
        uint256 maxPayout;
        uint256 recieved;
    }

    address public token;
    address public tradingAccount;

    uint256 public poolStartTime;

    uint256 private distributeAmountPoolAStorage;
    uint256 private distributeAmountPoolBStorage;
    uint256 private distributeAmountPoolCStorage;
    uint256 private distributeAmountLotteryStorage;

    uint256 private nonce;

    address public linkToken;
    address public vrfV2Wrapper;

    address public keeper;

    uint256[] public requestIds;
    uint256 public lastRequestId;

    uint32 callbackGasLimit = 500000;
    uint16 requestConfirmations = 3;

    uint32 numWords = 4;

    EnumerableSet.AddressSet private _dev;
    EnumerableSet.AddressSet private _stakersPoolA;
    EnumerableSet.AddressSet private _stakersPoolB;
    EnumerableSet.AddressSet private _stakersPoolC;
    EnumerableSet.AddressSet private _stakersTotal;

    EnumerableSet.AddressSet private _stakersPool_A_B;
    EnumerableSet.AddressSet private _winnerList;

    mapping(address => UserInfo) public userInfo;
    mapping(Group => GroupInfo) public groupInfo;

    mapping(uint256 => mapping(Group => address[])) private epochUsersByGroup;
    mapping(uint256 => mapping(address => uint256)) private epochUserIndex;
    mapping(uint256 => mapping(address => bool)) private isUserInEpochList;

    mapping(uint256 => uint256) private epochDepositAmount;

    mapping(uint256 => bool) private isEpochDistributed;
    mapping(address => Group) private winnerGroup;

    mapping(uint256 => mapping(uint256 => bool)) private epochStepDone;

    mapping(uint256 => RequestStatus) public s_requests;


    event Deposited(address indexed sender, Group group, uint256 amount, address indexed referrer);
    event ReferrerPaymentPaid(address indexed receiver, uint256 amount);
    event PoolBonusPaid(address indexed receiver, uint256 amount);
    event PoolBonusDistributed(address indexed receiver, uint256 amount);
    event LotteryBonusPaid(address indexed receiver, uint256 amount);
    event DevBonusPaid(address indexed receiver, uint256 amount);
    event TradingAccountFunded(address indexed receiver, uint256 amount);
    event Claimed(address user, uint256 amount);
    event RequestSent(uint256 requestId, uint32 numWords);
    event RequestFulfilled(uint256 requestId, uint256[] randomWords, uint256 payment);

    error MoneyTreeInvalidAddress(address account);
    error MoneyTreeInvalidKeeperAddress(address account);
    error MoneyTreeInvalidDevsLength(uint256 length);
    error MoneyTreeInvalidUserAddress(address user);
    error MoneyTreeUserAlreadyInList(address user);
    error MoneyTreeInvalidAmount(uint256 amount);
    error MoneyTreeInvalidReferrer(address referrer);
    error MoneyTreeInvalidStartTime(uint256 time);
    error MoneyTreeInvalidParameters();
    error MoneyTreeNotInWindow();
    error MoneyTreeInvalidGroup();
    error MoneyTreeInvalidGroupsParameters();
    error MoneyTreeZeroDistributedAmount();
    error MoneyTreeEpochIsDistributed();
    error MoneyTreeWindowwIsOpen();
    error MoneyTreeRequestNotFulfilled(uint256 request);
    error MoneyTreeStepNotReadyForExecute(uint256 step);


    modifier onlyKeeper(){
        if (msg.sender != keeper) {
            revert MoneyTreeInvalidKeeperAddress(msg.sender);
        }
        _;
    }


    constructor(address _linkToken, address _vrfV2Wrapper, address _keeper, address _token) VRFV2WrapperConsumerBase(_linkToken, _vrfV2Wrapper) {
        if (_keeper == address(0) ||
            _token == address(0)
        ) {
            revert MoneyTreeInvalidAddress(address(0));
        }
        keeper = _keeper;
        token = _token;
    }


    function initialize(address[] memory _devs, address _tradingAccount) external initializer onlyOwner returns (bool) {
        uint256 len = _devs.length;
        if (len != 11) revert MoneyTreeInvalidDevsLength(len);
        if (_tradingAccount == address(0)) revert MoneyTreeInvalidAddress(address(0));

        for (uint256 i = 0; i < len; i++) {
            if (_devs[i] == address(0)) revert MoneyTreeInvalidAddress(address(0));
            _dev.add(_devs[i]);
        }

        tradingAccount = _tradingAccount;

        return true;
    }

    function setPoolStartTime(uint256 _poolStartTime) external onlyOwner returns (bool) {
        if (_poolStartTime < block.timestamp) revert MoneyTreeInvalidStartTime(_poolStartTime);
        poolStartTime = _poolStartTime;
        return true;
    }

    function setGroupsInfo(Group[] memory _groups, GroupInfo[] memory _infos) external onlyOwner returns (bool) {
        if (_groups.length != _infos.length) revert MoneyTreeInvalidGroupsParameters();
        uint256 sum;
        for (uint256 i = 0; i < _groups.length; i++) {
            groupInfo[_groups[i]].depositSize = _infos[i].depositSize;
            groupInfo[_groups[i]].maxPayout = _infos[i].maxPayout;
            groupInfo[_groups[i]].distributionPercent = _infos[i].distributionPercent;
            sum += _infos[i].distributionPercent;
        }
        if (sum != DIVIDER) revert MoneyTreeInvalidGroupsParameters();
        return true;
    }

    function setLinkToken(address _linkToken) external onlyKeeper returns (bool) {
        if (_linkToken == address(0)) revert MoneyTreeInvalidAddress(address(0));
        linkToken = _linkToken;
        return true;
    }


    function deposit(Group _group, uint256 _amount, address _referrer) external returns (bool) {
        address _sender = msg.sender;
        if (!isTimeInWindow(block.timestamp)) revert MoneyTreeNotInWindow();
        if (stakersContainsByGroup(Group.TOTAL, _sender)) revert MoneyTreeUserAlreadyInList(_sender);
        if (_referrer != address(0) &&
            (!stakersContainsByGroup(Group.TOTAL, _referrer) ||
            stakersContainsByGroup(Group.DEV, _referrer) ||
            userInfo[_referrer].group != _group)) revert MoneyTreeInvalidReferrer(_referrer);
        if (_group != Group.POOL_A && _group != Group.POOL_B && _group != Group.POOL_C) revert MoneyTreeInvalidGroup();
        if (_amount != groupInfo[_group].depositSize) revert MoneyTreeInvalidAmount(_amount);

        uint256 currentEpoch = getEpoch(block.timestamp);

        IERC20(token).safeTransferFrom(_sender, address(this), _amount);
        epochDepositAmount[currentEpoch] += _amount;

        _stakersTotal.add(_sender);
        if (_group == Group.POOL_A) _stakersPoolA.add(_sender);
        if (_group == Group.POOL_B) _stakersPoolB.add(_sender);
        if (_group == Group.POOL_C) _stakersPoolC.add(_sender);
        if (_group == Group.POOL_A || _group == Group.POOL_B) _stakersPool_A_B.add(_sender);

        userInfo[_sender].group = _group;
        userInfo[_sender].deposited = true;

        addUserToGroupCurrentEpochList(_sender);

        if (_referrer != address(0)) {
            if (userInfo[_referrer].lastEpochAddReferrals == currentEpoch) {
                userInfo[_referrer].numberOfReferrals++;
            } else {
                userInfo[_referrer].numberOfReferrals = 1;
            }
            userInfo[_referrer].lastEpochAddReferrals = currentEpoch;

            if (userInfo[_referrer].numberOfReferrals == 3) {

                uint256 receivedAmount = userInfo[_referrer].totalReceived;
                uint256 depositSize = groupInfo[_group].depositSize;
                uint256 referrerMaxPayout = groupInfo[_group].maxPayout;

                if (depositSize * 2 >= referrerMaxPayout - receivedAmount) {

                    _stakersTotal.remove(_referrer);
                    if (_group == Group.POOL_A) _stakersPoolA.remove(_referrer);
                    if (_group == Group.POOL_B) _stakersPoolB.remove(_referrer);
                    if (_group == Group.POOL_C) _stakersPoolC.remove(_referrer);
                    if (_group == Group.POOL_A || _group == Group.POOL_B) _stakersPool_A_B.remove(_referrer);

                    removeUserFromGroupCurrentEpochList(_referrer);

                    userInfo[_referrer].deposited = false;
                    userInfo[_referrer].totalReceived = 0;
                    userInfo[_referrer].numberOfReferrals = 0;
                    userInfo[_referrer].lastEpochAddReferrals = 0;
                    userInfo[_referrer].winner = false;

                    _winnerList.add(_referrer);
                    winnerGroup[_referrer] = _group;


                    IERC20(token).safeTransfer(_referrer, referrerMaxPayout - receivedAmount);

                    epochDepositAmount[currentEpoch] -= (referrerMaxPayout - receivedAmount);

                    emit ReferrerPaymentPaid(_referrer, referrerMaxPayout - receivedAmount);

                } else {
                    userInfo[_referrer].totalReceived += depositSize * 2;
                    userInfo[_referrer].numberOfReferrals = 0;
                    IERC20(token).safeTransfer(_referrer, depositSize * 2);

                    epochDepositAmount[currentEpoch] -= depositSize * 2;

                    emit ReferrerPaymentPaid(_referrer, depositSize * 2);
                }
            }
        }

        emit Deposited(_sender, _group, _amount, _referrer);

        return true;
    }


    function claim() external nonReentrant returns (bool) {
        _claim(msg.sender);
        return true;
    }


    function requestRandomWords() external onlyKeeper returns (uint256 requestId) {
        requestId = requestRandomness(
            callbackGasLimit,
            requestConfirmations,
            numWords
        );
        s_requests[requestId] = RequestStatus({
            paid: VRF_V2_WRAPPER.calculateRequestPrice(callbackGasLimit),
            randomWords: new uint256[](0),
            fulfilled: false
        });
        requestIds.push(requestId);
        lastRequestId = requestId;
        emit RequestSent(requestId, numWords);
        return requestId;
    }


    function distrubuteStep01(uint256 _requestId) external onlyKeeper returns (bool) {

        (, bool fulfilled,) = getRequestStatus(_requestId);
        if (!fulfilled) revert MoneyTreeRequestNotFulfilled(_requestId);

        uint256 currentEpoch = getEpoch(block.timestamp);
        if (epochStepDone[currentEpoch][1]) revert MoneyTreeStepNotReadyForExecute(1);
        if (isTimeInWindow(block.timestamp)) revert MoneyTreeWindowwIsOpen();
        if (isEpochDistributed[currentEpoch] == true) revert MoneyTreeEpochIsDistributed();
        if (epochDepositAmount[currentEpoch] == 0) revert MoneyTreeZeroDistributedAmount();

        Values memory v;
        uint256[] memory groupAmounts = calculateGroupDistribution(epochDepositAmount[currentEpoch]);

        v.distributeAmountDev = groupAmounts[0];
        distributeAmountPoolAStorage = groupAmounts[1];
        distributeAmountPoolBStorage = groupAmounts[2];
        distributeAmountPoolCStorage = groupAmounts[3];
        distributeAmountLotteryStorage = groupAmounts[4];
        v.distributeAmountTrading = groupAmounts[5];

        // payDev
        v.devPaymentAmount = v.distributeAmountDev / 11;

        for (uint256 i = 0; i < 11; i++) {
            if (i == 10) {
                v.recipient = _dev.at(i);
                IERC20(token).safeTransfer(v.recipient, v.distributeAmountDev - v.devPaymentAmount * 10);
                break;
            }
            v.recipient = _dev.at(i);
            IERC20(token).safeTransfer(v.recipient, v.devPaymentAmount);

            emit DevBonusPaid(v.recipient, v.devPaymentAmount);
        }

        //  payTradingAccount
        IERC20(token).safeTransfer(tradingAccount, v.distributeAmountTrading);

        epochStepDone[currentEpoch][1] = true;

        emit TradingAccountFunded(tradingAccount, v.distributeAmountTrading);

        return true;
    }


    function distrubuteStep02(uint256 _requestId) external onlyKeeper returns (bool) {

        uint256 currentEpoch = getEpoch(block.timestamp);
        if (!epochStepDone[currentEpoch][1] || epochStepDone[currentEpoch][2]) revert MoneyTreeStepNotReadyForExecute(2);

        Values memory v;

        v.distributeAmountPoolA = distributeAmountPoolAStorage;

        //   payPoolA
        v.len = epochUsersByGroup[currentEpoch][Group.POOL_A].length;
        if (v.len > 0) {

            v.maxPoolAmountForBonusROI = v.distributeAmountPoolA * 3 / 4;
            v.maxUsersForROIBonus = v.maxPoolAmountForBonusROI / groupInfo[Group.POOL_A].depositSize;

            v.usersForROIBonus = (v.maxUsersForROIBonus > v.len / 4) ? v.len / 4 : v.maxUsersForROIBonus;

            for (uint256 i = 0; i < v.usersForROIBonus; i++) {
                v.len = epochUsersByGroup[currentEpoch][Group.POOL_A].length;

                v.winnerIndex = processRandomness(_requestId, 0, v.len);
                v.winnerAddress = epochUsersByGroup[currentEpoch][Group.POOL_A][v.winnerIndex];

                (v.winnerPayment, v.winnersStayInList) = payWinner(v.winnerAddress);
                if (v.winnersStayInList) {
                    userInfo[v.winnerAddress].winner = true;
                    v.numberOfWinnersStayInList++;
                }

                v.distributeAmountPoolA -= v.winnerPayment;
                removeUserFromGroupCurrentEpochList(v.winnerAddress);
            }
        }

        v.numberUsersInPool = stakersLengthByGroup(Group.POOL_A) - v.numberOfWinnersStayInList;

        if (v.numberUsersInPool > 0) {

            v.distributePayment = v.distributeAmountPoolA / v.numberUsersInPool;
            v.maxPayout = groupInfo[Group.POOL_A].maxPayout;

            for (uint256 i = stakersLengthByGroup(Group.POOL_A) - 1; i >= 0; i--) {
                v.recipient = stakersByGroup(Group.POOL_A, i);

                if (userInfo[v.recipient].winner == true) {
                    userInfo[v.recipient].winner = false;
                } else {

                    v.recieved = userInfo[v.recipient].totalReceived;

                    if (v.distributePayment >= v.maxPayout - v.recieved) {
                        _stakersTotal.remove(v.recipient);
                        _stakersPoolA.remove(v.recipient);
                        _stakersPool_A_B.remove(v.recipient);

                        userInfo[v.recipient].deposited = false;
                        userInfo[v.recipient].totalReceived = 0;
                        userInfo[v.recipient].numberOfReferrals = 0;
                        userInfo[v.recipient].lastEpochAddReferrals = 0;
                        userInfo[v.recipient].winner = false;

                        _winnerList.add(v.recipient);
                        winnerGroup[v.recipient] = Group.POOL_A;

                        IERC20(token).safeTransfer(v.recipient, v.maxPayout - v.recieved);
                        v.distributeAmountPoolA -= (v.maxPayout - v.recieved);

                        emit PoolBonusPaid(v.recipient, v.maxPayout - v.recieved);

                    } else {
                        userInfo[v.recipient].totalReceived += v.distributePayment;
                        userInfo[v.recipient].availableToClaim += v.distributePayment;
                        userInfo[v.recipient].numberOfReferrals = 0;

                        v.distributeAmountPoolA -= v.distributePayment;

                        emit PoolBonusDistributed(v.recipient, v.distributePayment);
                    }
                }

                if (i == 0) {
                    break;
                }
            }

            distributeAmountPoolBStorage += v.distributeAmountPoolA;
            distributeAmountPoolAStorage = 0;

            v.numberOfWinnersStayInList = 0;

        } else {

            distributeAmountPoolBStorage += v.distributeAmountPoolA;
            distributeAmountPoolAStorage = 0;
        }

        epochStepDone[currentEpoch][2] = true;

        return true;
    }


    function distrubuteStep03(uint256 _requestId) external onlyKeeper returns (bool) {

        uint256 currentEpoch = getEpoch(block.timestamp);
        if (!epochStepDone[currentEpoch][2] || epochStepDone[currentEpoch][3]) revert MoneyTreeStepNotReadyForExecute(3);

        Values memory v;

        v.distributeAmountPoolB = distributeAmountPoolBStorage;

        //   payPoolB
        v.len = epochUsersByGroup[currentEpoch][Group.POOL_B].length;
        if (v.len > 0) {

            v.maxPoolAmountForBonusROI = v.distributeAmountPoolB * 3 / 4;
            v.maxUsersForROIBonus = v.maxPoolAmountForBonusROI / groupInfo[Group.POOL_B].depositSize;

            v.usersForROIBonus = (v.maxUsersForROIBonus > v.len / 4) ? v.len / 4 : v.maxUsersForROIBonus;

            for (uint256 i = 0; i < v.usersForROIBonus; i++) {
                v.len = epochUsersByGroup[currentEpoch][Group.POOL_B].length;

                v.winnerIndex = processRandomness(_requestId, 1, v.len);
                v.winnerAddress = epochUsersByGroup[currentEpoch][Group.POOL_B][v.winnerIndex];

                (v.winnerPayment, v.winnersStayInList) = payWinner(v.winnerAddress);
                if (v.winnersStayInList) {
                    userInfo[v.winnerAddress].winner = true;
                    v.numberOfWinnersStayInList++;
                }

                v.distributeAmountPoolB -= v.winnerPayment;
                removeUserFromGroupCurrentEpochList(v.winnerAddress);
            }
        }

        v.numberUsersInPool = stakersLengthByGroup(Group.POOL_B) - v.numberOfWinnersStayInList;

        if (v.numberUsersInPool > 0) {

            v.distributePayment = v.distributeAmountPoolB / v.numberUsersInPool;
            v.maxPayout = groupInfo[Group.POOL_B].maxPayout;

            for (uint256 i = stakersLengthByGroup(Group.POOL_B) - 1; i >= 0; i--) {
                v.recipient = stakersByGroup(Group.POOL_B, i);

                if (userInfo[v.recipient].winner == true) {
                    userInfo[v.recipient].winner = false;
                } else {

                    v.recieved = userInfo[v.recipient].totalReceived;

                    if (v.distributePayment >= v.maxPayout - v.recieved) {
                        _stakersTotal.remove(v.recipient);
                        _stakersPoolB.remove(v.recipient);
                        _stakersPool_A_B.remove(v.recipient);

                        userInfo[v.recipient].deposited = false;
                        userInfo[v.recipient].totalReceived = 0;
                        userInfo[v.recipient].numberOfReferrals = 0;
                        userInfo[v.recipient].lastEpochAddReferrals = 0;
                        userInfo[v.recipient].winner = false;

                        _winnerList.add(v.recipient);
                        winnerGroup[v.recipient] = Group.POOL_B;


                        IERC20(token).safeTransfer(v.recipient, v.maxPayout - v.recieved);
                        v.distributeAmountPoolB -= (v.maxPayout - v.recieved);

                        emit PoolBonusPaid(v.recipient, v.maxPayout - v.recieved);

                    } else {
                        userInfo[v.recipient].totalReceived += v.distributePayment;
                        userInfo[v.recipient].availableToClaim += v.distributePayment;
                        userInfo[v.recipient].numberOfReferrals = 0;

                        v.distributeAmountPoolB -= v.distributePayment;

                        emit PoolBonusDistributed(v.recipient, v.distributePayment);
                    }
                }

                if (i == 0) {
                    break;
                }
            }

            distributeAmountPoolCStorage += v.distributeAmountPoolB;
            distributeAmountPoolBStorage = 0;

            v.numberOfWinnersStayInList = 0;

        } else {

            distributeAmountPoolCStorage += v.distributeAmountPoolB;
            distributeAmountPoolBStorage = 0;
        }

        epochStepDone[currentEpoch][3] = true;

        return true;
    }


    function distrubuteStep04(uint256 _requestId) external onlyKeeper returns (bool) {

        uint256 currentEpoch = getEpoch(block.timestamp);
        if (!epochStepDone[currentEpoch][3] || epochStepDone[currentEpoch][4]) revert MoneyTreeStepNotReadyForExecute(4);

        Values memory v;

        v.distributeAmountPoolC = distributeAmountPoolCStorage;

        //   payPoolC
        v.len = epochUsersByGroup[currentEpoch][Group.POOL_C].length;
        if (v.len > 0) {

            v.maxPoolAmountForBonusROI = v.distributeAmountPoolC * 3 / 4;
            v.maxUsersForROIBonus = v.maxPoolAmountForBonusROI / groupInfo[Group.POOL_C].depositSize;

            v.usersForROIBonus = (v.maxUsersForROIBonus > v.len / 4) ? v.len / 4 : v.maxUsersForROIBonus;

            for (uint256 i = 0; i < v.usersForROIBonus; i++) {
                v.len = epochUsersByGroup[currentEpoch][Group.POOL_C].length;

                v.winnerIndex = processRandomness(_requestId, 2, v.len);
                v.winnerAddress = epochUsersByGroup[currentEpoch][Group.POOL_C][v.winnerIndex];

                (v.winnerPayment, v.winnersStayInList) = payWinner(v.winnerAddress);
                if (v.winnersStayInList) {
                    userInfo[v.winnerAddress].winner = true;
                    v.numberOfWinnersStayInList++;
                }

                v.distributeAmountPoolC -= v.winnerPayment;
                removeUserFromGroupCurrentEpochList(v.winnerAddress);
            }
        }

        v.numberUsersInPool = stakersLengthByGroup(Group.POOL_C) - v.numberOfWinnersStayInList;

        if (v.numberUsersInPool > 0) {

            v.distributePayment = v.distributeAmountPoolC / v.numberUsersInPool;
            v.maxPayout = groupInfo[Group.POOL_C].maxPayout;

            for (uint256 i = stakersLengthByGroup(Group.POOL_C) - 1; i >= 0; i--) {
                v.recipient = stakersByGroup(Group.POOL_C, i);

                if (userInfo[v.recipient].winner == true) {
                    userInfo[v.recipient].winner = false;
                } else {

                    v.recieved = userInfo[v.recipient].totalReceived;

                    if (v.distributePayment >= v.maxPayout - v.recieved) {
                        _stakersTotal.remove(v.recipient);
                        _stakersPoolC.remove(v.recipient);

                        userInfo[v.recipient].deposited = false;
                        userInfo[v.recipient].totalReceived = 0;
                        userInfo[v.recipient].numberOfReferrals = 0;
                        userInfo[v.recipient].lastEpochAddReferrals = 0;
                        userInfo[v.recipient].winner = false;

                        _winnerList.add(v.recipient);
                        winnerGroup[v.recipient] = Group.POOL_C;


                        IERC20(token).safeTransfer(v.recipient, v.maxPayout - v.recieved);
                        v.distributeAmountPoolC -= (v.maxPayout - v.recieved);

                        emit PoolBonusPaid(v.recipient, v.maxPayout - v.recieved);

                    } else {
                        userInfo[v.recipient].totalReceived += v.distributePayment;
                        userInfo[v.recipient].availableToClaim += v.distributePayment;
                        userInfo[v.recipient].numberOfReferrals = 0;

                        v.distributeAmountPoolC -= v.distributePayment;

                        emit PoolBonusDistributed(v.recipient, v.distributePayment);
                    }
                }

                if (i == 0) {
                    break;
                }
            }

            distributeAmountLotteryStorage += v.distributeAmountPoolC;
            distributeAmountPoolCStorage = 0;

            v.numberOfWinnersStayInList = 0;

        } else {

            distributeAmountLotteryStorage += v.distributeAmountPoolC;
            distributeAmountPoolCStorage = 0;
        }

        epochStepDone[currentEpoch][4] = true;

        return true;
    }


    function distrubuteStep05(uint256 _requestId) external onlyKeeper returns (uint256) {

        uint256 currentEpoch = getEpoch(block.timestamp);
        if (!epochStepDone[currentEpoch][4] || epochStepDone[currentEpoch][5]) revert MoneyTreeStepNotReadyForExecute(5);

        Values memory v;

        v.distributeAmountLottery = distributeAmountLotteryStorage;

        //   payLottery
        while (v.distributeAmountLottery > 0) {

            v.len = _stakersPool_A_B.length();

            v.winnerIndex = processRandomness(_requestId, 3, v.len);

            v.winnerAddress = _stakersPool_A_B.at(v.winnerIndex);


            Group _winnerGroup = userInfo[v.winnerAddress].group;
            v.recieved = userInfo[v.winnerAddress].totalReceived;
            v.maxPayout = groupInfo[_winnerGroup].maxPayout;

            v.winnerPayment = v.maxPayout - v.recieved;

            if (v.distributeAmountLottery >= v.winnerPayment) {

                _stakersTotal.remove(v.winnerAddress);
                if (_winnerGroup == Group.POOL_A) _stakersPoolA.remove(v.winnerAddress);
                if (_winnerGroup == Group.POOL_B) _stakersPoolB.remove(v.winnerAddress);
                if (_winnerGroup == Group.POOL_A || _winnerGroup == Group.POOL_B) _stakersPool_A_B.remove(v.winnerAddress);

                IERC20(token).safeTransfer(v.winnerAddress, v.winnerPayment);

                userInfo[v.winnerAddress].deposited = false;
                userInfo[v.winnerAddress].totalReceived = 0;
                userInfo[v.winnerAddress].numberOfReferrals = 0;
                userInfo[v.winnerAddress].lastEpochAddReferrals = 0;
                userInfo[v.winnerAddress].winner = false;

                _winnerList.add(v.winnerAddress);
                winnerGroup[v.winnerAddress] = _winnerGroup;

                v.distributeAmountLottery -= v.winnerPayment;

                emit LotteryBonusPaid(v.winnerAddress, v.winnerPayment);

            } else {

                userInfo[v.winnerAddress].totalReceived += v.distributeAmountLottery;
                userInfo[v.winnerAddress].numberOfReferrals = 0;
                IERC20(token).safeTransfer(v.winnerAddress, v.distributeAmountLottery);

                emit LotteryBonusPaid(v.winnerAddress, v.distributeAmountLottery);

                v.distributeAmountLottery = 0;
            }

        }

        epochStepDone[currentEpoch][4] = true;

        isEpochDistributed[currentEpoch] = true;

        return v.distributeAmountLottery;
    }


    function winners(uint256 _index) external view returns (address) {
        return _winnerList.at(_index);
    }

    function winnerListContains(address _user) external view returns (bool) {
        return _winnerList.contains(_user);
    }

    function winnerListLength() external view returns (uint256) {
        return _winnerList.length();
    }

    function getWinnerList(uint256 offset, uint256 limit) external view returns (address[] memory output) {
        uint256 _winnerListLength = _winnerList.length();
        if (offset >= _winnerListLength) return new address[](0);
        uint256 to = offset + limit;
        if (_winnerListLength < to) to = _winnerListLength;
        output = new address[](to - offset);
        for (uint256 i = 0; i < output.length; i++) output[i] = _winnerList.at(offset + i);
    }

    function getUserInfo(address _user)
    external view returns (
        Group group,
        bool deposited,
        uint256 totalReceived,
        uint256 availableToClaim,
        uint256 numberOfReferrals,
        uint256 lastEpochAddReferrals,
        bool winner
    )
    {
        if (!userInfo[_user].deposited) revert MoneyTreeInvalidUserAddress(_user);

        UserInfo memory info = userInfo[_user];
        return (
        info.group,
        info.deposited,
        info.totalReceived,
        info.availableToClaim,
        info.numberOfReferrals,
        info.lastEpochAddReferrals,
        info.winner
        );
    }


    function getWinnerGroup(address _user) external view returns (Group group) {
        return winnerGroup[_user];
    }


    function getEpochDepositAmount(uint256 _epoch) external view returns (uint256) {
        return epochDepositAmount[_epoch];
    }


    function withdrawLink() public onlyKeeper returns (bool) {
        LinkTokenInterface link = LinkTokenInterface(linkToken);
        link.transfer(msg.sender, link.balanceOf(address(this)));
        return true;
    }

    function stakersByGroup(Group _group, uint256 _index) public view returns (address) {
        if (_group == Group.DEV) {
            return _dev.at(_index);
        } else if (_group == Group.POOL_A) {
            return _stakersPoolA.at(_index);
        } else if (_group == Group.POOL_B) {
            return _stakersPoolB.at(_index);
        } else if (_group == Group.POOL_C) {
            return _stakersPoolC.at(_index);
        } else if (_group == Group.TOTAL) {
            return _stakersTotal.at(_index);
        } else {
            revert MoneyTreeInvalidGroup();
        }
    }

    function stakersContainsByGroup(Group _group, address _user) public view returns (bool) {
        if (_group == Group.DEV) {
            return _dev.contains(_user);
        } else if (_group == Group.POOL_A) {
            return _stakersPoolA.contains(_user);
        } else if (_group == Group.POOL_B) {
            return _stakersPoolB.contains(_user);
        } else if (_group == Group.POOL_C) {
            return _stakersPoolC.contains(_user);
        } else if (_group == Group.TOTAL) {
            return _stakersTotal.contains(_user);
        } else {
            revert MoneyTreeInvalidGroup();
        }
    }

    function stakersLengthByGroup(Group _group) public view returns (uint256) {
        if (_group == Group.DEV) {
            return _dev.length();
        } else if (_group == Group.POOL_A) {
            return _stakersPoolA.length();
        } else if (_group == Group.POOL_B) {
            return _stakersPoolB.length();
        } else if (_group == Group.POOL_C) {
            return _stakersPoolC.length();
        } else if (_group == Group.TOTAL) {
            return _stakersTotal.length();
        } else {
            revert MoneyTreeInvalidGroup();
        }
    }

    function getStakersList(Group _group, uint256 offset, uint256 limit) public view returns (address[] memory output) {
        uint256 _stakersListLength;
        uint256 to;
        if (_group == Group.POOL_A) {
            _stakersListLength = _stakersPoolA.length();
            if (offset >= _stakersListLength) return new address[](0);
            to = offset + limit;
            if (_stakersListLength < to) to = _stakersListLength;
            output = new address[](to - offset);
            for (uint256 i = 0; i < output.length; i++) output[i] = _stakersPoolA.at(offset + i);
        } else if (_group == Group.POOL_B) {
            _stakersListLength = _stakersPoolB.length();
            if (offset >= _stakersListLength) return new address[](0);
            to = offset + limit;
            if (_stakersListLength < to) to = _stakersListLength;
            output = new address[](to - offset);
            for (uint256 i = 0; i < output.length; i++) output[i] = _stakersPoolB.at(offset + i);
        } else if (_group == Group.POOL_C) {
            _stakersListLength = _stakersPoolC.length();
            if (offset >= _stakersListLength) return new address[](0);
            to = offset + limit;
            if (_stakersListLength < to) to = _stakersListLength;
            output = new address[](to - offset);
            for (uint256 i = 0; i < output.length; i++) output[i] = _stakersPoolC.at(offset + i);
        } else if (_group == Group.TOTAL) {
            _stakersListLength = _stakersTotal.length();
            if (offset >= _stakersListLength) return new address[](0);
            to = offset + limit;
            if (_stakersListLength < to) to = _stakersListLength;
            output = new address[](to - offset);
            for (uint256 i = 0; i < output.length; i++) output[i] = _stakersTotal.at(offset + i);
        } else {
            revert MoneyTreeInvalidGroup();
        }
    }

    function getEpochUsersByGroup(Group _group) public view returns (address[] memory) {
        uint256 _currentEpoch = getEpoch(block.timestamp);
        return epochUsersByGroup[_currentEpoch][_group];
    }


    function getEpochUserIndex(address _user) public view returns (uint256) {
        uint256 _currentEpoch = getEpoch(block.timestamp);
        return epochUserIndex[_currentEpoch][_user];
    }


    function _isUserInEpochList(address _user) public view returns (bool) {
        uint256 _currentEpoch = getEpoch(block.timestamp);
        return isUserInEpochList[_currentEpoch][_user];
    }


    function isTimeInWindow(uint256 _time) public view returns (bool) {
        if (_time < poolStartTime) revert MoneyTreeInvalidParameters();
        uint256 diff = _time - poolStartTime;
        return diff - (diff / 1 weeks) * 1 weeks < 1 days;
    }


    function getEpoch(uint256 _time) public view returns (uint256) {
        if (_time < poolStartTime) revert MoneyTreeInvalidParameters();
        uint256 diff = _time - poolStartTime;
        return diff / 1 weeks + 1;
    }


    function getRequestStatus(uint256 _requestId) public view returns (uint256 paid, bool fulfilled, uint256[] memory randomWords) {
        require(s_requests[_requestId].paid > 0, "request not found");
        RequestStatus memory request = s_requests[_requestId];
        return (request.paid, request.fulfilled, request.randomWords);
    }


    function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
        require(s_requests[_requestId].paid > 0, "request not found");
        s_requests[_requestId].fulfilled = true;
        s_requests[_requestId].randomWords = _randomWords;
        emit RequestFulfilled(
            _requestId,
            _randomWords,
            s_requests[_requestId].paid
        );
    }


    function payWinner(address _user) private returns (uint256 payment, bool winnersStayInList) {
        Group userGroup = userInfo[_user].group;
        uint256 receivedAmount = userInfo[_user].totalReceived;
        uint256 depositSize = groupInfo[userGroup].depositSize;
        uint256 userMaxPayout = groupInfo[userGroup].maxPayout;

        if (depositSize >= userMaxPayout - receivedAmount) {

            _stakersTotal.remove(_user);
            if (userGroup == Group.POOL_A) _stakersPoolA.remove(_user);
            if (userGroup == Group.POOL_B) _stakersPoolB.remove(_user);
            if (userGroup == Group.POOL_C) _stakersPoolC.remove(_user);
            if (userGroup == Group.POOL_A || userGroup == Group.POOL_B) _stakersPool_A_B.remove(_user);

            userInfo[_user].deposited = false;
            userInfo[_user].totalReceived = 0;
            userInfo[_user].numberOfReferrals = 0;
            userInfo[_user].lastEpochAddReferrals = 0;
            userInfo[_user].winner = false;

            _winnerList.add(_user);
            winnerGroup[_user] = userGroup;

            IERC20(token).safeTransfer(_user, userMaxPayout - receivedAmount);

            payment = userMaxPayout - receivedAmount;

            emit PoolBonusPaid(_user, userMaxPayout - receivedAmount);

        } else {
            userInfo[_user].totalReceived += depositSize;
            userInfo[_user].numberOfReferrals = 0;
            userInfo[_user].winner = true;
            IERC20(token).safeTransfer(_user, depositSize);

            payment = depositSize;

            winnersStayInList = true;

            emit PoolBonusPaid(_user, depositSize);
        }
    }


    function addUserToGroupCurrentEpochList(address _user) private {
        uint256 _currentEpoch = getEpoch(block.timestamp);
        Group _userGroup = userInfo[_user].group;

        epochUserIndex[_currentEpoch][_user] = epochUsersByGroup[_currentEpoch][_userGroup].length;
        isUserInEpochList[_currentEpoch][_user] = true;
        epochUsersByGroup[_currentEpoch][_userGroup].push(_user);
    }


    function removeUserFromGroupCurrentEpochList(address _user) private {
        uint256 _currentEpoch = getEpoch(block.timestamp);
        Group _userGroup = userInfo[_user].group;
        if (isUserInEpochList[_currentEpoch][_user]) {
            uint256 lastUserIndex = epochUsersByGroup[_currentEpoch][_userGroup].length - 1;
            uint256 userIndex = epochUserIndex[_currentEpoch][_user];

            address lastUserAddress = epochUsersByGroup[_currentEpoch][_userGroup][lastUserIndex];
            epochUsersByGroup[_currentEpoch][_userGroup][userIndex] = lastUserAddress;
            epochUserIndex[_currentEpoch][lastUserAddress] = userIndex;

            delete epochUserIndex[_currentEpoch][_user];
            isUserInEpochList[_currentEpoch][_user] = false;

            epochUsersByGroup[_currentEpoch][_userGroup].pop();
        }
    }


    function _claim(address _user) private {
        UserInfo storage user = userInfo[_user];
        uint256 claimAmount = user.availableToClaim;
        if (claimAmount > 0) {
            user.availableToClaim = 0;
            IERC20(token).safeTransfer(_user, claimAmount);
            emit Claimed(_user, claimAmount);
        }
    }


    function processRandomness(uint256 _requestId, uint256 _k, uint256 _size) private returns (uint256 _randomness) {
        (,,uint256[] memory _randomWords) = getRequestStatus(_requestId);
        nonce++;
        _randomness = uint256(keccak256(abi.encode(_randomWords[_k], blockhash(block.number), _size, nonce)));
        _randomness = _randomness % _size;
    }


    function calculateGroupDistribution(uint256 _totalAmount) private view returns (uint256[] memory) {
        uint256[] memory _amounts = new uint256[](6);
        _amounts[0] = _totalAmount * groupInfo[Group.DEV].distributionPercent / DIVIDER;
        _amounts[1] = _totalAmount * groupInfo[Group.POOL_A].distributionPercent / DIVIDER;
        _amounts[2] = _totalAmount * groupInfo[Group.POOL_B].distributionPercent / DIVIDER;
        _amounts[3] = _totalAmount * groupInfo[Group.POOL_C].distributionPercent / DIVIDER;
        _amounts[4] = _totalAmount * groupInfo[Group.LOTTERY].distributionPercent / DIVIDER;
        _amounts[5] = _totalAmount - _amounts[0] - _amounts[1] - _amounts[2] - _amounts[3] - _amounts[4];
        return _amounts;
    }
}
