// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

contract MockERC20 {
    string public constant name = "Mock Token";
    string public constant symbol = "MOCK";
    uint8 public constant decimals = 18;

    bool public returnFalse;
    address public revertRecipient;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function setReturnFalse(bool returnFalse_) external {
        returnFalse = returnFalse_;
    }

    function setRevertRecipient(address revertRecipient_) external {
        revertRecipient = revertRecipient_;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (to == revertRecipient) {
            revert("MOCK_RECIPIENT");
        }
        if (returnFalse) {
            return false;
        }

        require(balanceOf[from] >= amount, "MOCK_BALANCE");
        require(allowance[from][msg.sender] >= amount, "MOCK_ALLOWANCE");

        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        return true;
    }
}

contract NoReturnERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(balanceOf[from] >= amount, "NO_RETURN_BALANCE");
        require(allowance[from][msg.sender] >= amount, "NO_RETURN_ALLOWANCE");

        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract BrokenQueryERC20 {
    enum QueryMode {
        Ok,
        Revert,
        Short,
        Empty
    }

    QueryMode public balanceMode;
    QueryMode public allowanceMode;

    uint256 public balanceValue = 1_000;
    uint256 public allowanceValue = 1_000;

    function setBalanceMode(QueryMode balanceMode_) external {
        balanceMode = balanceMode_;
    }

    function setAllowanceMode(QueryMode allowanceMode_) external {
        allowanceMode = allowanceMode_;
    }

    fallback() external {
        if (msg.sig == bytes4(keccak256("balanceOf(address)"))) {
            _returnByMode(balanceMode, balanceValue);
        }
        if (msg.sig == bytes4(keccak256("allowance(address,address)"))) {
            _returnByMode(allowanceMode, allowanceValue);
        }

        revert("UNKNOWN_SELECTOR");
    }

    function _returnByMode(QueryMode mode, uint256 value) internal pure {
        if (mode == QueryMode.Revert) {
            revert("BROKEN_QUERY");
        }
        if (mode == QueryMode.Empty) {
            assembly {
                return(0x00, 0x00)
            }
        }
        if (mode == QueryMode.Short) {
            assembly {
                mstore(0x00, 1)
                return(0x1f, 1)
            }
        }

        assembly {
            mstore(0x00, value)
            return(0x00, 0x20)
        }
    }
}

contract ShortReturnERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    fallback() external {
        if (msg.sig != bytes4(keccak256("transferFrom(address,address,uint256)"))) {
            revert("UNKNOWN_SELECTOR");
        }

        assembly {
            mstore(0x00, 1)
            return(0x1f, 1)
        }
    }
}

contract RejectNative {
    receive() external payable {
        revert("REJECT_NATIVE");
    }
}
