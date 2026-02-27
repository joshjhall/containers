
# Python development aliases
alias fmt='black . && isort .'
alias lint='flake8 && mypy . && pylint **/*.py'
alias pyt='pytest'
alias pytv='pytest -v'
alias pytcov='pytest --cov=. --cov-report=html'
alias notebook='jupyter notebook'
alias lab='jupyter lab'
alias ipy='ipython'

# Smart wrapper functions that detect and use Poetry when available
# These override the aliases when Poetry is detected
_smart_pytest() {
    if [ -f "pyproject.toml" ] && command -v poetry &> /dev/null && poetry env info --path &> /dev/null; then
        poetry run pytest "$@"
    else
        command pytest "$@"
    fi
}

_smart_pytest_verbose() {
    if [ -f "pyproject.toml" ] && command -v poetry &> /dev/null && poetry env info --path &> /dev/null; then
        poetry run pytest -v "$@"
    else
        command pytest -v "$@"
    fi
}

_smart_pytest_coverage() {
    if [ -f "pyproject.toml" ] && command -v poetry &> /dev/null && poetry env info --path &> /dev/null; then
        poetry run pytest --cov=. --cov-report=html "$@"
    else
        command pytest --cov=. --cov-report=html "$@"
    fi
}

_smart_format() {
    if [ -f "pyproject.toml" ] && command -v poetry &> /dev/null && poetry env info --path &> /dev/null; then
        poetry run black . && poetry run isort .
    else
        command black . && command isort .
    fi
}

_smart_lint() {
    if [ -f "pyproject.toml" ] && command -v poetry &> /dev/null && poetry env info --path &> /dev/null; then
        poetry run flake8 && poetry run mypy . && poetry run pylint **/*.py
    else
        command flake8 && command mypy . && command pylint **/*.py
    fi
}

_smart_ipython() {
    if [ -f "pyproject.toml" ] && command -v poetry &> /dev/null && poetry env info --path &> /dev/null; then
        poetry run ipython "$@"
    else
        command ipython "$@"
    fi
}

# Override aliases with functions when in interactive mode
# This allows the smart detection to work while keeping familiar command names
if [[ $- == *i* ]]; then
    function pyt() { _smart_pytest "$@"; }
    function pytv() { _smart_pytest_verbose "$@"; }
    function pytcov() { _smart_pytest_coverage "$@"; }
    function fmt() { _smart_format "$@"; }
    function lint() { _smart_lint "$@"; }
    function ipy() { _smart_ipython "$@"; }
fi

# Pre-commit helpers
alias pc='pre-commit'
alias pcall='pre-commit run --all-files'
alias pcinstall='pre-commit install'

# Unified workflow aliases
alias py-format-all='black . && isort .'
alias py-lint-all='ruff check . && flake8 && mypy . && pylint **/*.py 2>/dev/null || true'
alias py-security-check='bandit -r . && pip-audit'
