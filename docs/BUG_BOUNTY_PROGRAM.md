# TetraGold Bug Bounty Program

## Program Overview

**Launch Date**: January 2025  
**Duration**: Ongoing (Initial 3-month intensive period)  
**Total Rewards Pool**: $100,000 USD  
**Scope**: Smart contracts, frontend, oracle system, infrastructure

## Scope and Targets

### In-Scope Assets

#### Smart Contracts (Primary Focus)
- **TGAUx Token Contract**: `0x742d35Cc6634C0532925a3b8D4C9db96C4b5Da5f`
- **Oracle Aggregator**: `0x8A791620dd6260079BF849Dc5567aDC3F2FdC318`
- **Circuit Breaker**: `0x610178dA211FEF7D417bC0e6FeD39F05609AD788`
- **Timelock Controller**: `0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e`
- **Interface Contracts**: All interface definitions

#### Frontend Application
- **Web Application**: https://testnet.tetragold.io
- **API Endpoints**: All backend services
- **Authentication**: Wallet connection and session management
- **Data Handling**: User input validation and sanitization

#### Oracle System
- **Price Aggregation**: Multi-source oracle logic
- **Data Validation**: Staleness and deviation checks
- **Failover Mechanisms**: Oracle failure handling
- **Price Manipulation**: Resistance testing

#### Infrastructure
- **Network Security**: RPC endpoints and node security
- **Database Security**: Data storage and access controls
- **API Security**: Rate limiting and authentication
- **Monitoring Systems**: Alert and logging mechanisms

### Out-of-Scope
- **Third-party Services**: Chainlink, Band Protocol, Infura
- **Social Engineering**: Phishing, social attacks
- **Physical Security**: Hardware and facility security
- **Denial of Service**: Network flooding attacks
- **Previously Known Issues**: Documented limitations

## Reward Structure

### Critical Severity: $10,000 - $25,000
- **Smart Contract**: Direct fund loss or theft
- **Oracle Manipulation**: Price feed compromise
- **Access Control**: Admin privilege escalation
- **Upgrade Vulnerabilities**: Proxy implementation flaws
- **Economic Attacks**: Infinite minting or fee bypass

### High Severity: $5,000 - $15,000
- **Smart Contract**: Indirect fund loss or lock
- **Oracle Issues**: Significant price deviation
- **Authentication**: Unauthorized access
- **Data Integrity**: Corruption or manipulation
- **Circuit Breaker**: Bypass or malfunction

### Medium Severity: $1,000 - $5,000
- **Smart Contract**: Griefing or DoS attacks
- **Frontend**: XSS, CSRF, or injection flaws
- **API Security**: Rate limiting bypass
- **Information Disclosure**: Sensitive data exposure
- **Logic Errors**: Incorrect calculations

### Low Severity: $250 - $1,000
- **UI/UX Issues**: Minor security implications
- **Information Leakage**: Non-sensitive data
- **Configuration**: Suboptimal security settings
- **Documentation**: Security-relevant inaccuracies
- **Best Practices**: Minor deviations

### Informational: $50 - $250
- **Code Quality**: Security-adjacent improvements
- **Documentation**: Clarity and completeness
- **Testing**: Missing test cases
- **Monitoring**: Blind spots or gaps
- **Compliance**: Regulatory considerations

## Submission Guidelines

### Report Requirements

#### Vulnerability Details
- **Title**: Clear, descriptive summary
- **Severity**: Self-assessed impact level
- **Description**: Detailed explanation of the issue
- **Impact**: Potential consequences and affected users
- **Reproduction**: Step-by-step instructions
- **Proof of Concept**: Code, screenshots, or videos
- **Remediation**: Suggested fixes or mitigations

#### Technical Information
- **Environment**: Network, browser, tools used
- **Contracts**: Specific addresses and functions
- **Transactions**: Hash IDs for on-chain evidence
- **Logs**: Relevant error messages or outputs
- **Timeline**: Discovery date and testing period

#### Supporting Materials
- **Code Snippets**: Exploit code or test cases
- **Screenshots**: Visual evidence of the issue
- **Videos**: Demonstration of exploitation
- **Documentation**: Relevant specifications or standards
- **References**: Similar vulnerabilities or research

### Submission Process

1. **Initial Report**: Submit via security@tetragold.io
2. **Acknowledgment**: Response within 24 hours
3. **Triage**: Severity assessment within 72 hours
4. **Investigation**: Detailed analysis and validation
5. **Remediation**: Fix development and testing
6. **Verification**: Confirm resolution effectiveness
7. **Reward**: Payment processing and recognition

### Communication Guidelines
- **Confidentiality**: No public disclosure until fixed
- **Cooperation**: Work with team for clarification
- **Patience**: Allow reasonable time for fixes
- **Professionalism**: Respectful and constructive communication
- **Updates**: Regular status updates provided

## Evaluation Criteria

### Severity Assessment Factors

#### Impact Scoring
- **Confidentiality**: Data exposure or privacy breach
- **Integrity**: Data modification or corruption
- **Availability**: Service disruption or denial
- **Financial**: Direct or indirect monetary loss
- **Reputation**: Brand damage or user trust impact

#### Exploitability Factors
- **Attack Complexity**: Skill and resources required
- **Prerequisites**: Special access or conditions needed
- **Reliability**: Consistency of successful exploitation
- **Automation**: Potential for automated attacks
- **Scale**: Number of users or assets affected

#### Business Context
- **User Impact**: Effect on end users and experience
- **Regulatory**: Compliance and legal implications
- **Competitive**: Advantage to competitors
- **Operational**: Impact on business operations
- **Strategic**: Effect on long-term goals

### Quality Criteria
- **Originality**: Novel or previously unknown issues
- **Clarity**: Well-documented and reproducible
- **Completeness**: Thorough analysis and testing
- **Constructiveness**: Helpful suggestions for fixes
- **Timeliness**: Prompt and responsible disclosure

## Responsible Disclosure

### Disclosure Timeline
- **Day 0**: Initial vulnerability report received
- **Day 1**: Acknowledgment and initial triage
- **Day 3**: Severity assessment and investigation start
- **Day 14**: Preliminary fix development
- **Day 30**: Fix testing and validation
- **Day 45**: Deployment and verification
- **Day 60**: Public disclosure (if appropriate)

### Disclosure Guidelines
- **No Public Disclosure**: Until fix is deployed
- **Coordinated Release**: Joint announcement if desired
- **Credit Attribution**: Recognition in security advisories
- **Embargo Period**: Minimum 30 days for critical issues
- **Exception Handling**: Emergency procedures for active exploitation

### Researcher Responsibilities
- **Good Faith**: Genuine security research intent
- **Minimal Impact**: Avoid data destruction or service disruption
- **Privacy Respect**: No access to user data or accounts
- **Legal Compliance**: Follow applicable laws and regulations
- **Confidentiality**: Maintain secrecy until disclosure

## Legal Framework

### Safe Harbor
Researchers acting in good faith under this program will not face legal action for:
- **Security Testing**: Authorized vulnerability research
- **Data Access**: Minimal necessary for proof of concept
- **Service Disruption**: Unintentional minor impacts
- **Disclosure**: Following responsible disclosure guidelines

### Terms and Conditions
- **Eligibility**: Open to all security researchers
- **Exclusions**: TetraGold employees and immediate family
- **Taxes**: Researcher responsible for tax obligations
- **Disputes**: Arbitration through agreed-upon process
- **Modifications**: Program terms may be updated

### Prohibited Activities
- **Social Engineering**: Targeting employees or users
- **Physical Attacks**: Hardware or facility compromise
- **Denial of Service**: Intentional service disruption
- **Data Destruction**: Deleting or corrupting data
- **Spam/Noise**: Low-quality or duplicate reports

## Recognition and Rewards

### Hall of Fame
- **Public Recognition**: Listed on security page
- **Achievement Levels**: Based on contribution quality
- **Annual Awards**: Top researcher recognition
- **Conference Speaking**: Opportunity to present findings
- **Networking**: Access to security community events

### Reward Processing
- **Payment Method**: Cryptocurrency or bank transfer
- **Processing Time**: 30 days after fix deployment
- **Tax Documentation**: 1099 forms for US researchers
- **Currency**: USD equivalent at time of payment
- **Minimum Threshold**: $50 minimum payout

### Bonus Rewards
- **First Discovery**: 25% bonus for novel vulnerability classes
- **Exceptional Quality**: Up to 50% bonus for outstanding reports
- **Multiple Issues**: Cumulative rewards for related findings
- **Collaboration**: Additional recognition for helpful cooperation
- **Innovation**: Bonus for creative testing methodologies

## Program Management

### Security Team
- **Program Lead**: security-lead@tetragold.io
- **Technical Lead**: tech-security@tetragold.io
- **Communications**: security-comms@tetragold.io
- **Legal Counsel**: legal@tetragold.io

### Review Process
- **Triage Team**: Initial assessment and routing
- **Technical Review**: Deep dive analysis and validation
- **Business Impact**: Risk assessment and prioritization
- **Remediation Team**: Fix development and testing
- **Quality Assurance**: Verification and deployment

### Continuous Improvement
- **Monthly Reviews**: Program effectiveness assessment
- **Researcher Feedback**: Surveys and improvement suggestions
- **Industry Benchmarking**: Comparison with peer programs
- **Process Optimization**: Streamlining and automation
- **Scope Evolution**: Expanding coverage as system grows

## Resources and Support

### Documentation
- **Technical Docs**: Architecture and implementation guides
- **API Documentation**: Endpoint specifications and examples
- **Smart Contract Code**: Verified source code on Etherscan
- **Test Suite**: Comprehensive test cases and scenarios
- **Security Framework**: Detailed security model documentation

### Testing Environment
- **Testnet Access**: Sepolia deployment for safe testing
- **Test Tokens**: Faucet access for transaction testing
- **Monitoring Tools**: Real-time system health dashboards
- **Debug Information**: Enhanced logging for researchers
- **Sandbox Environment**: Isolated testing capabilities

### Community Support
- **Discord Channel**: #bug-bounty for researcher discussions
- **Office Hours**: Weekly Q&A sessions with security team
- **Webinars**: Educational content on system architecture
- **Mentorship**: Guidance for new security researchers
- **Collaboration**: Opportunities to work with other researchers

---

**Program Launch**: January 2025  
**Contact**: security@tetragold.io  
**Updates**: Monthly program reviews and improvements  
**Legal**: Terms subject to change with 30-day notice