// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {VRFCoordinatorV2Interface} from "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import {VRFConsumerBaseV2} from "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

/**
 * @title A sample Raffle contract
 * @author Owen Chan
 * @notice This contract is for creating a sample raffle
 * @dev Implements ChainLink VRFv2
 */
contract Raffle is VRFConsumerBaseV2 {
    error Raffle__NotEnoughEthSent();
    error Raffle__TransferFailed();
    error Raffle__RaffleNotOpen();
    error Raffle__UpkeepNotNeeded(
        uint256 currentBalance,
        uint256 numPlayers,
        uint256 raffleState
    );

    /** Type declarations */
    // 声明一个枚举，标记抽奖状态
    enum RaffleState {
        OPEN, // 0开放
        CALCULATING // 1计算中
    }

    /** State Variables */
    uint16 private constant REQUEST_CONFIRMATIONS = 3; // 获取随机数所需要的区块确认数量
    uint32 private constant NUM_WORDS = 1; // 请求几个随机数

    uint256 private immutable i_entranceFee; // 门票费
    uint256 private immutable i_interval; // 抽一次奖的间隔时间
    VRFCoordinatorV2Interface private immutable i_vrfCoordinator; // VRF协调合约的接口
    bytes32 private immutable i_gasLane; // 使用哪种服务，高速-中速-低速，Gas费不一样
    uint64 private immutable i_subscriptionId; // 我们的订阅ID
    uint32 private immutable i_callbackGasLimit; // 返回随机数的Gas限制

    address payable[] private s_players; // 参与者地址数组
    uint256 private s_lastTimeStamp; // 上一次抽完奖的时间戳
    address private s_recentWinner; // 最近得奖者
    RaffleState private s_raffleState; // 新建一个枚举变量

    /** Events */
    event RequestedRaffleWinner(uint256 indexed requestId);
    event EnteredRaffle(address indexed player);
    event PickedWinner(address indexed winner);

    constructor(
        uint256 entranceFee,
        uint256 interval,
        address vrfCoordinator,
        bytes32 gasLane,
        uint64 subscriptionId,
        uint32 callbackGasLimit
    ) VRFConsumerBaseV2(vrfCoordinator) {
        i_entranceFee = entranceFee;
        i_interval = interval;
        i_vrfCoordinator = VRFCoordinatorV2Interface(vrfCoordinator); // 把传入的vrf地址链接接口，方便调用其中的函数
        i_gasLane = gasLane;
        i_subscriptionId = subscriptionId;
        i_callbackGasLimit = callbackGasLimit;

        // 初始化计时
        s_lastTimeStamp = block.timestamp;
        s_raffleState = RaffleState.OPEN;
    }

    // Set to payable, allowing participants to pay tokens when calling functions
    function enterRaffle() external payable {
        if (msg.value < i_entranceFee) {
            revert Raffle__NotEnoughEthSent();
        }
        if (s_raffleState != RaffleState.OPEN) {
            revert Raffle__RaffleNotOpen();
        }
        // 把函数调用者的地址存进s_player数组中
        s_players.push(payable(msg.sender));
        emit EnteredRaffle(msg.sender);
    }

    /**
     * @dev 这个函数满足以下条件会触发
     * 1. 时长间隔满足
     * 2. 抽奖状态是OPEN
     * 3. 合约里面有ETH，也就是有玩家参与抽奖
     * 4. 订阅里面有LINK余额
     */
    function checkUpkeep(
        bytes memory /* checkData */
    ) public view returns (bool upkeepNeeded, bytes memory /* performData */) {
        bool timeHasPassed = ((block.timestamp - s_lastTimeStamp) >=
            i_interval);
        bool isOpen = RaffleState.OPEN == s_raffleState;
        bool hasBalance = address(this).balance > 0;
        bool hasPlayers = s_players.length > 0;
        upkeepNeeded = (timeHasPassed && isOpen && hasBalance && hasPlayers);
        return (upkeepNeeded, "0x0");
    }

    function performUpkeep(bytes calldata /* performData */) external {
        (bool upkeepNeeded, ) = checkUpkeep("");
        if (!upkeepNeeded) {
            // 自定义错误可以在发生回滚时显示错误参数，需要在上面定义error的时候把返回变量类型加上
            revert Raffle__UpkeepNotNeeded(
                address(this).balance,
                s_players.length,
                uint256(s_raffleState)
            );
        }
        s_raffleState = RaffleState.CALCULATING;
        // 调用请求随机数的函数后会返回一个请求ID（不是订阅ID）
        uint256 requestId = i_vrfCoordinator.requestRandomWords(
            i_gasLane, // 使用哪种服务，高速-中速-低速，Gas费不一样
            i_subscriptionId, // 我们的订阅ID
            REQUEST_CONFIRMATIONS, // 获取随机数所需要的区块确认数量
            i_callbackGasLimit, // 返回随机数的Gas限制
            NUM_WORDS // 请求几个随机数
        );

        emit RequestedRaffleWinner(requestId);
    }

    // 这里的逻辑是：
    // 1. 链上的Chainlink协调合约(Coordinator)会发送一个requestId和一个(或几个)randomWords回来，把他们传入VRFConsumerBaseV2.sol中的rawFulfillRandomWords函数
    // 2. rawFulfillRandomWords函数会检测该调用者是不是Chainlink协调合约(Coordinator),如果不是会回滚，如果是则执行第三步
    // 3. rawFulfillRandomWords函数调用fulfullRandomWords函数，fulfullRandomWords函数在VRFConsumerBaseV2.sol中只是一个虚拟函数，必须在我们当前的合约中被重写
    // 4. rawFulfillRandomWords函数将requestId和randomWords -> fulfullRandomWords函数，因此我们就从外部拿到了requestId和randomWords
    // 总结：实际上是Chainlink链上的合约在调用我们写的合约，每当我们请求一次随机数，过一段时间后协调合约就会调用我们的合约函数，把随机数返回给我们
    function fulfillRandomWords(
        uint256 /* requestId */,
        uint256[] memory randomWords
    ) internal override {
        uint256 indexOfWinner = randomWords[0] % s_players.length;
        address payable winner = s_players[indexOfWinner];
        s_recentWinner = winner;
        s_raffleState = RaffleState.OPEN;
        s_players = new address payable[](0);
        s_lastTimeStamp = block.timestamp;

        emit PickedWinner(winner);

        (bool success, ) = s_recentWinner.call{value: address(this).balance}(
            ""
        );
        if (!success) {
            revert Raffle__TransferFailed();
        }
    }

    /** Getter Function */
    function getEntranceFee() external view returns (uint256) {
        return i_entranceFee;
    }

    function getRaffleState() external view returns (RaffleState) {
        return s_raffleState;
    }

    function getPlayer(uint256 indexOfPlayer) external view returns (address) {
        return s_players[indexOfPlayer];
    }
}
