# shellcheck disable=SC2155
# ----------------------------------------------------------------------------
# AWS CLI Configuration and Helpers
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi


# ----------------------------------------------------------------------------
# AWS CLI Aliases - Common AWS operations
# ----------------------------------------------------------------------------
alias awsprofile='aws configure list-profiles'     # List available profiles
alias awswho='aws sts get-caller-identity'        # Show current identity
alias awsregion='aws configure get region'        # Show current region
alias awsls='aws s3 ls'                          # List S3 buckets/objects
alias awsec2='aws ec2 describe-instances --query "Reservations[*].Instances[*].[InstanceId,State.Name,Tags[?Key==\`Name\`].Value|[0]]" --output table'
alias awslogs='aws logs tail'                    # Tail CloudWatch logs

# AWS CLI auto-completion
if command -v aws_completer &> /dev/null; then
    complete -C aws_completer aws
fi

# ----------------------------------------------------------------------------
# aws-profile - Switch between AWS profiles or show current profile
#
# Arguments:
#   $1 - Profile name (optional)
#
# Examples:
#   aws-profile              # Show current profile and list available
#   aws-profile production   # Switch to production profile
# ----------------------------------------------------------------------------
aws-profile() {
    if [ -z "$1" ]; then
        echo "Current profile: $AWS_PROFILE"
        echo "Available profiles:"
        aws configure list-profiles
    else
        export AWS_PROFILE="$1"
        echo "Switched to AWS profile: $AWS_PROFILE"
        aws sts get-caller-identity
    fi
}

# ----------------------------------------------------------------------------
# aws-assume-role - Assume an IAM role and export temporary credentials
#
# Arguments:
#   $1 - Role ARN (required)
#   $2 - Session name (optional)
#
# Example:
#   aws-assume-role arn:aws:iam::123456789012:role/MyRole
# ----------------------------------------------------------------------------
aws-assume-role() {
    if [ -z "$1" ]; then
        echo "Usage: aws-assume-role <role-arn> [session-name]"
        return 1
    fi

    local role_arn="$1"
    local session_name="${2:-cli-session-$(date +%s)}"

    # Validate ARN format to prevent command injection
    if ! [[ "$role_arn" =~ ^arn:aws:iam::[0-9]{12}:role/[a-zA-Z0-9+=,.@_/-]+$ ]]; then
        echo "Error: Invalid IAM role ARN format" >&2
        echo "Expected: arn:aws:iam::<account-id>:role/<role-name>" >&2
        return 1
    fi

    # Sanitize session name (AWS allows alphanumeric and =,.@_-)
    # Remove any characters not in allowed set and limit to 64 chars
    session_name=$(echo "$session_name" | tr -cd 'a-zA-Z0-9=,.@_-' | cut -c1-64)

    if [ -z "$session_name" ]; then
        echo "Error: Invalid session name after sanitization" >&2
        return 1
    fi

    local creds=$(aws sts assume-role \
        --role-arn "$role_arn" \
        --role-session-name "$session_name" \
        --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
        --output text)

    export AWS_ACCESS_KEY_ID=$(echo "$creds" | awk '{print $1}')
    export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | awk '{print $2}')
    export AWS_SESSION_TOKEN=$(echo "$creds" | awk '{print $3}')

    echo "Assumed role: $role_arn"
    aws sts get-caller-identity
}

# ----------------------------------------------------------------------------
# aws-regions - List all AWS regions or set default region
#
# Arguments:
#   $1 - Region code (optional)
#
# Examples:
#   aws-regions              # List all regions
#   aws-regions us-west-2    # Set default region
# ----------------------------------------------------------------------------
aws-regions() {
    if [ -z "$1" ]; then
        echo "Current region: $(aws configure get region || echo 'Not set')"
        echo
        echo "Available regions:"
        aws ec2 describe-regions --query 'Regions[*].[RegionName,Endpoint]' --output table
    else
        aws configure set region "$1"
        echo "Default region set to: $1"
    fi
}

# ----------------------------------------------------------------------------
# aws-mfa - Generate MFA session tokens
#
# Arguments:
#   $1 - MFA device ARN (required)
#   $2 - MFA token code (required)
#
# Example:
#   aws-mfa arn:aws:iam::123456789012:mfa/user 123456
# ----------------------------------------------------------------------------
aws-mfa() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "Usage: aws-mfa <mfa-device-arn> <token-code>"
        return 1
    fi

    local mfa_arn="$1"
    local token_code="$2"

    local creds=$(aws sts get-session-token \
        --serial-number "$mfa_arn" \
        --token-code "$token_code" \
        --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
        --output text)

    export AWS_ACCESS_KEY_ID=$(echo $creds | awk '{print $1}')
    export AWS_SECRET_ACCESS_KEY=$(echo $creds | awk '{print $2}')
    export AWS_SESSION_TOKEN=$(echo $creds | awk '{print $3}')

    echo "MFA session established"
    aws sts get-caller-identity
}

# ----------------------------------------------------------------------------
# aws-sso-login - Simplified SSO login
#
# Arguments:
#   $1 - Profile name (optional, uses AWS_PROFILE if not specified)
#
# Example:
#   aws-sso-login mycompany-dev
# ----------------------------------------------------------------------------
aws-sso-login() {
    local profile="${1:-${AWS_PROFILE:-default}}"
    export AWS_PROFILE="$profile"
    aws sso login --profile "$profile"
    echo "SSO login complete for profile: $profile"
    aws sts get-caller-identity
}

# AWS CLI auto-completion
if command -v aws_completer &> /dev/null; then
    complete -C aws_completer aws
fi


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
