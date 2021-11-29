// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import "@chainlink/contracts/src/v0.8/ConfirmedOwner.sol";

contract DispatchEscrow is ChainlinkClient, ConfirmedOwner {
    
    /*
    This contract is a proof of concept and should not be used in production
    
    TODO: 
        Optimise integer size
        Allow more flexible percentage release gates
        Contract ownership and transfer
        Revisit visibility of functions and state vars
        Safe Transfers
        Openzeppelin best pracs
        Gas optimisation
        Extract chainlink logic into external adapter and handle logic there so that contract can rely on specific return values across carriers
        Consider restructuring around open zeppelin escrow contract base
        Add deadlines to incentivise seller and carrier service and to support cancellation on failed delivery
    */

    //Oracle state variables
    using Chainlink for Chainlink.Request;
    address private oracleNode;
    bytes32 private oracleJobId;
    uint256 private oracleFee;
    mapping(bytes32 => uint256) private oracleRequestsToJobs; 
    
    //Jobs 
    mapping(uint256 => Job) private jobs; 
    
    uint256 nextJobId;
    
    struct Job {
        address seller;
        address buyer;
        uint256 salePrice;
        //uint256 transitDeadline;
        //uint256 deliveryDeadline;
        uint256 trackingActiveSharePercentage;
        uint256 inTransitSharePercentage;
        uint256 deliverySharePercentage;
        JobState state;
        uint256 sellerEarnedBalance;
        uint256 buyerEarnedBalance;
        uint256 sellerWithdrawnBalance;
        uint256 buyerWithdrawnBalance;
        bytes32 trackingCode;
    }
    
    enum JobState { Created, Accepted, TrackingActive, InTransit, Delivered } 

    //Modifier functions
    modifier jobExists(uint256 _jobId) {
        //A job should always have a seller, else it hasn't been created yet
        require(jobs[_jobId].seller != address(0), "job does not exist");
        _;
    }
    
    modifier jobInState(uint256 _jobId, JobState _state) {
        require(jobs[_jobId].state == _state, "the function cannot be called at the current state");
        _;
    }

    modifier onlyBuyer(uint256 _jobId) {
        require(msg.sender == jobs[_jobId].buyer, "caller is not the buyer, or job does not exist");
        _;
    }

    modifier onlySeller(uint256 _jobId) {
        require(msg.sender == jobs[_jobId].seller, "caller is not the seller, or job does not exist");
        _;
    }

    modifier onlyBuyerOrSeller(uint256 _jobId) {
        require(
            msg.sender == jobs[_jobId].buyer || msg.sender == jobs[_jobId].seller, 
            "caller is not the buyer or the seller, or job does not exist");
        _;
    }

    //Events
    event CreateJob(
        uint256 indexed jobId,
        address indexed buyer,
        address indexed seller,
        uint256 salePrice,
        //uint256 transitDeadline,
        //uint256 deliveryDeadline,
        uint256 trackingActiveSharePercentage,
        uint256 inTransitSharePercentage,
        uint256 deliverySharePercentage
    );
    event JobUpdated(uint256 indexed jobId, JobState state);
    event BalancesUpdated(uint256 indexed _jobId, uint256 buyerEarnedBalance, uint256 sellerEarnedBalance, uint256 sellerWithdrawnBalance, uint256 buyerWithdrawnBalance);
    event JobStateUpdateSaved(uint256 indexed _jobId, JobState _newstate);
    event JobStateUpdateStart(uint256 indexed _jobId);
    event JobStateUpdateReturned(uint256 indexed _jobId, bytes32 _latestStatus, bytes32 _requestId);
    event JobWithdrawal(uint256 _jobId, address _userAddress, uint256 _amount);

    /*  
        The only functional kovan nodes on the marketplace, for whatever reason
        Kovan: https://market.link/nodes/4f97910d-3893-4f04-80f9-e6f2fad84445/jobs?network=42
        Rinkeby: https://market.link/nodes/fcb85e5f-dc96-4776-97a0-b7865e895d29/jobs?network=4
        Mumbai: https://market.link/nodes/63a49b1a-1951-4887-8f3f-8684d70c41ea/jobs?network=80001
        Fee: 0.1 LINK
        
    */
    constructor() ConfirmedOwner(msg.sender){
        nextJobId = 1;
        setPublicChainlinkToken();
        oracleNode = 0xF405B99ACa8578B9eb989ee2b69D518aaDb90c1F; 
        oracleJobId = "7c4b968028f74b2eabd7d428f03ba45c";
        oracleFee = 0.1 * 10 ** 18; 
    }
    

    //Lodge a job internally, typically called by a buyer or seller function
    function createJob(
        address seller,
        address buyer,
        uint256 salePrice,
        //uint256 transitDeadline,
        //uint256 deliveryDeadline,
        uint256 trackingActiveSharePercentage,
        uint256 inTransitSharePercentage,
        uint256 deliverySharePercentage
    ) 
        internal 
        returns(uint256) 
    {
        //Shares must equal 100%
        require((trackingActiveSharePercentage + inTransitSharePercentage + deliverySharePercentage) == 100, "Shares do not equal 100%");
        
        //Create the job and increment the job counter ready for the next one
        uint256 jobId = nextJobId;     
        jobs[jobId] = Job({
            seller: seller,
            buyer: buyer,
            salePrice: salePrice,
            //transitDeadline: transitDeadline,
            //deliveryDeadline: deliveryDeadline,
            trackingActiveSharePercentage: trackingActiveSharePercentage,
            inTransitSharePercentage: inTransitSharePercentage,
            deliverySharePercentage: deliverySharePercentage,
            state: JobState.Created,
            sellerEarnedBalance: 0,
            buyerEarnedBalance: 0,
            sellerWithdrawnBalance: 0,
            buyerWithdrawnBalance:0,
            trackingCode: ""
        });  
        nextJobId++;
        
        emit CreateJob(jobId, buyer, seller, salePrice, trackingActiveSharePercentage, inTransitSharePercentage, deliverySharePercentage);
        
        return jobId;
    }
    
    //Retrieve a job by its ID
    function getJob(uint256 _jobId)
        external
        view
        jobExists(_jobId)
        returns (
            address seller,
            address buyer,
            uint256 salePrice,
            //uint256 transitDeadline,
            //uint256 deliveryDeadline,
            uint256 trackingActiveSharePercentage,
            uint256 inTransitSharePercentage,
            uint256 deliverySharePercentage,
            JobState state,
            uint256 sellerEarnedBalance,
            uint256 buyerEarnedBalance,
            uint256 sellerWithdrawnBalance,
            uint256 buyerWithdrawnBalance,
            bytes32 trackingCode
        )
    {
        seller = jobs[_jobId].seller;
        buyer = jobs[_jobId].buyer;
        salePrice = jobs[_jobId].salePrice;
        //transitDeadline = jobs[_jobId].transitDeadline;
        //deliveryDeadline = jobs[_jobId].deliveryDeadline;
        trackingActiveSharePercentage = jobs[_jobId].trackingActiveSharePercentage;
        inTransitSharePercentage = jobs[_jobId].inTransitSharePercentage;
        deliverySharePercentage = jobs[_jobId].deliverySharePercentage;
        state = jobs[_jobId].state;
        sellerEarnedBalance = jobs[_jobId].sellerEarnedBalance;
        buyerEarnedBalance = jobs[_jobId].buyerEarnedBalance;
        sellerWithdrawnBalance = jobs[_jobId].sellerWithdrawnBalance;
        buyerWithdrawnBalance = jobs[_jobId].buyerWithdrawnBalance;
        trackingCode = jobs[_jobId].trackingCode;

    }

    //Seller offers item to buyer with terms. Sale price is in wei so saleprice should be Eth * 10 **18
    //JSVM
    //BUYER_ACCOUNT,1000000000000000000,10,60,30

    //metamask acct3
    //BUYER_ACCOUNT,1000000000000000000,10,60,30
    function sellerOffer(
        address _buyer,
        uint256 _salePrice,
        //uint256 _transitDeadline,
        //uint256 _deliveryDeadline,
        uint256 _trackingActiveSharePercentage,
        uint256 _inTransitSharePercentage,
        uint256 _deliverySharePercentage
        ) 
        public
        returns(uint256)
    {
        uint256 _jobId = createJob(
            msg.sender, _buyer,
            _salePrice,
            //_transitDeadline,
            //_deliveryDeadline,
            _trackingActiveSharePercentage,
            _inTransitSharePercentage,
            _deliverySharePercentage
        );
        return _jobId;
    }

    //buyer accepts offer and must pay the asking price
    function buyerAcceptOffer(uint256 _jobId) 
        external 
        jobInState(_jobId, JobState.Created)
        onlyBuyer(_jobId)
        payable
        
    {
        //Revert and return funds if amount sent does not equal offer total
        Job storage job = jobs[_jobId];
        require(msg.value == job.salePrice, "sent amount does not match salePrice");

        job.state = JobState.Accepted;
        job.buyerEarnedBalance = job.salePrice;
        emit JobUpdated(_jobId, JobState.Accepted);
    }

    //seller adds tracking
    //cancelled PP39tBecv7QSspk
    //completed ppfmri9pbzlmq
    function sellerAddTracking(uint256 _jobId, string memory _trackingCodeString)
        public
        onlySeller(_jobId)
    {
        //TODO: Consider whether seller should be able to update tracking if already set
        bytes32 _trackingCodeBytes = stringToBytes32(_trackingCodeString);
        Job storage job = jobs[_jobId];
        job.trackingCode = _trackingCodeBytes;
    }

    //request tracking status update from external API via Chainlink, balances updated when response is recieved in fulfullment function
    //allow anyone to update balances if they want to pay for it
    function requestBalanceUpdate(uint256 _jobId)
        public
        jobExists(_jobId)
        returns (bytes32 requestId)
    {
        Job memory job = jobs[_jobId];
        require(job.trackingCode != "", "tracking code has not been added yet");

        
        Chainlink.Request memory request = buildChainlinkRequest(oracleJobId, address(this), this.fulfill.selector);
        //Format: https://app.shippit.com/api/3/orders/TRACKING_CODE/tracking
        string memory requestUrl = concatenateStrings(concatenateStrings("https://app.shippit.com/api/3/orders/", bytes32ToString(job.trackingCode)), "/tracking");
        request.add("get", requestUrl);
        //most recent track event
        request.add("path", "response.track.0.status");
        requestId =  sendChainlinkRequestTo(oracleNode, request, oracleFee);
        
        //Store list of requests mapped to jobs so that we can tell which job to update in fulfillment
        oracleRequestsToJobs[requestId] = _jobId; 
    }

    //Chainlink returns with an API response so we trigger state changes and balance updates
    function fulfill(bytes32 _requestId, bytes32 _latestStatus) 
        public 
        recordChainlinkFulfillment(_requestId)
    {
        //TODO: Extract response checking logic to Chainlink external adapter, so that logic here can be made generic across carriers

        //We have many jobs so need to look up which job tracking update response relates to
        uint256 _jobId = oracleRequestsToJobs[_requestId];

        //Check that the job still exists, as it could have been cleaned up during the request
        require(jobs[_jobId].seller != address(0), "job does not exist");
        Job storage job = jobs[_jobId];

        //Check for matches to each carrier status, with most optimistic check first to save on computation, then perform updates only if status has changed
    
        //Delivered
        if((_latestStatus == bytes32(bytes("parcel_completed")) || _latestStatus == bytes32(bytes("completed"))) && job.state != JobState.Delivered) {
            job.state = JobState.Delivered;
            updateJobEarnedBalances(_jobId);
        }
        //In transit with carrier
        else if((_latestStatus == bytes32(bytes("in_transit")) || _latestStatus == bytes32(bytes("with_driver"))) && job.state != JobState.InTransit) {
            job.state = JobState.InTransit;
            updateJobEarnedBalances(_jobId);
        }
        //Tracking confirmed active. Lodged with carrier, but not yet in transit
        else if((_latestStatus == bytes32(bytes("order_placed")) || _latestStatus == bytes32(bytes("despatch_in_progress")) || _latestStatus == bytes32(bytes("ready_for_pickup"))) && job.state != JobState.TrackingActive) {
            job.state = JobState.TrackingActive;
            updateJobEarnedBalances(_jobId);
        }
        else {
            //TODO: Error state to be handled, requires deadlines to be built out, enabling cancellation flows
        }
    }

    //Fake a job state change. A function that bypasses chainlink API calls to simplify local testing.
    function fakeStateChange(uint256 _jobId, JobState _newState) 
        public
        onlyBuyerOrSeller(_jobId)
    {
        Job storage job = jobs[_jobId];
        
        //force update job state
        job.state = _newState;

        //trigger balance updates
        updateJobEarnedBalances(_jobId);
    }
  
    function updateJobEarnedBalances(uint256 _jobId)
        jobExists(_jobId)
        internal
    {
        Job storage job = jobs[_jobId];
        
        //Calculate value transfer
        uint256 _sellerEarnedBalance = 0;

        //TODO: safe math for indivisible integers. Below will result in rounding errors.
        if(job.state == JobState.Delivered) {
            _sellerEarnedBalance = job.salePrice * (job.trackingActiveSharePercentage + job.inTransitSharePercentage + job.deliverySharePercentage) / 100;
        }
        else if(job.state == JobState.InTransit) {
            _sellerEarnedBalance = job.salePrice * (job.trackingActiveSharePercentage + job.inTransitSharePercentage) / 100;
        }
        else if(job.state == JobState.TrackingActive) {
            _sellerEarnedBalance = job.salePrice * job.trackingActiveSharePercentage / 100;
        }
        else if(job.state == JobState.Accepted) {
            _sellerEarnedBalance = 0;
        }
        
        //update earned balances
        job.sellerEarnedBalance = _sellerEarnedBalance;
        job.buyerEarnedBalance = job.salePrice - _sellerEarnedBalance;

        emit BalancesUpdated(_jobId, job.buyerEarnedBalance, job.sellerEarnedBalance, job.sellerWithdrawnBalance, job.buyerWithdrawnBalance);
    }
    
    //get users balance that is available for withdrawal.
    function getJobAvailableBalanceForAddress(uint256 _jobId, address _who)
        public  
        view
        jobExists(_jobId)
        returns(uint256)
    {
        require(msg.sender == jobs[_jobId].buyer || msg.sender == jobs[_jobId].seller, "address is not the buyer or the seller");

        Job memory job = jobs[_jobId];
        
        uint availableUserBalance;
        if(_who == job.buyer){
            availableUserBalance = job.buyerEarnedBalance - job.buyerWithdrawnBalance;
        }
        if(_who == job.seller){
            availableUserBalance = job.sellerEarnedBalance - job.sellerWithdrawnBalance;
        }
        return availableUserBalance;
    }

    //needs review, very simple POC transfer not safe
    function withdraw(uint256 _jobId, uint256 _amount) 
        public
        payable
        onlyBuyerOrSeller(_jobId)
    {
        require(_amount > 0, "amount is zero");
        
        address payable _userAddress = payable(msg.sender);

        uint256 _availableUserBalance = getJobAvailableBalanceForAddress(_jobId, _userAddress);
        require(_availableUserBalance >= _amount, "amount exceeds the available balance");
        
        Job storage job = jobs[_jobId];

        if(_userAddress== job.seller){
            job.sellerWithdrawnBalance = job.sellerWithdrawnBalance + _amount;
            _userAddress.transfer(_amount);
        }
        if(_userAddress == job.buyer){
            //Buyer can withdraw if they have accepted but not if the seller has added tracking
            require(job.state == JobState.Accepted, "buyer can only withdraw in accepted state");
            job.buyerWithdrawnBalance = job.buyerWithdrawnBalance + _amount;
            _userAddress.transfer(_amount);
        }
        emit JobWithdrawal(_jobId, _userAddress, _amount);
        //TODO: Delete job if balances are zero for both buyer and seller. Cleans up job list.        
    }

    //UTILITIES

    //Retrieves LINK token address to aid with withdrawals
    function getChainlinkToken() public view returns (address) {
        return chainlinkTokenAddress();
    }

    //Transfers contract LINK balance to owner
    function withdrawLink() public onlyOwner {
        LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
        require(link.transfer(msg.sender, link.balanceOf(address(this))), "Unable to transfer");
    }

    //Cancels a chainlink request
    function cancelRequest(
        bytes32 _requestId,
        uint256 _payment,
        bytes4 _callbackFunctionId,
        uint256 _expiration
    )
        public
        onlyOwner
    {
        cancelChainlinkRequest(_requestId, _payment, _callbackFunctionId, _expiration);
    }
    
    //Convert type bytes32 to string
    function bytes32ToString(bytes32 _bytes32) 
        internal 
        pure 
        returns (string memory) 
    {
        uint8 i = 0;
        while(i < 32 && _bytes32[i] != 0) {
            i++;
        }
        bytes memory bytesArray = new bytes(i);
        for (i = 0; i < 32 && _bytes32[i] != 0; i++) {
            bytesArray[i] = _bytes32[i];
        }
        return string(bytesArray);
    }
    
    //Convert type string to bytes32
    function stringToBytes32(string memory source) 
        internal 
        pure 
        returns (bytes32 result) 
    {
        bytes memory tempEmptyStringTest = bytes(source);
        if (tempEmptyStringTest.length == 0) {
            return 0x0;
        }

        assembly { // solhint-disable-line no-inline-assembly
            result := mload(add(source, 32))
        }
    }

    //Join two strings together
    function concatenateStrings(string memory a,string memory b) 
        public 
        pure 
        returns (string memory)
    {
        return string(abi.encodePacked(a,b));
    }

}
