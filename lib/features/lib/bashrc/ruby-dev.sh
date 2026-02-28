# ----------------------------------------------------------------------------
# Ruby development tools configuration
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi


# RSpec configuration
export SPEC_OPTS="--format documentation --color"

# Pry configuration
export PRY_THEME="solarized"

# Bundler audit configuration
export BUNDLE_AUDIT_UPDATE_ON_INSTALL=true

# Spring configuration (Rails preloader)
export SPRING_TMP_PATH="/tmp/spring"

# Ruby development aliases
alias be='bundle exec'
alias ber='bundle exec rspec'
alias bert='bundle exec rake test'
alias beru='bundle exec rubocop'
alias berg='bundle exec rails generate'
alias berc='bundle exec rails console'
alias bers='bundle exec rails server'

# RSpec aliases
alias rspec-fast='rspec --fail-fast'
alias rspec-seed='rspec --order random'

# Rubocop aliases
alias rubocop-fix='rubocop -a'
alias rubocop-fix-all='rubocop -A'

# Bundle aliases
alias bundle-outdated='bundle outdated --strict'
alias bundle-security='bundle-audit check --update'

# Helper functions
# Run tests for modified files only
rspec-changed() {
    git diff --name-only --diff-filter=AM | command grep '_spec.rb$' | xargs bundle exec rspec
}

# Profile Ruby code
ruby-profile() {
    ruby -r stackprof -e "StackProf.run(mode: :cpu, out: 'tmp/stackprof.dump') { load '$1' }"
    stackprof tmp/stackprof.dump
}


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
