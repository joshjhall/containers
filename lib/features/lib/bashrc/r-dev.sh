# ----------------------------------------------------------------------------
# R Development Tool Aliases and Functions
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
# R Development Tool Aliases
# ----------------------------------------------------------------------------
# RStudio-like shortcuts
alias rcheck='R CMD check'
alias rbuild='R CMD build'
alias rinstall='R CMD INSTALL'
alias rdoc='R CMD Rd2pdf'

# Devtools shortcuts
alias rdev-check='Rscript -e "devtools::check()"'
alias rdev-test='Rscript -e "devtools::test()"'
alias rdev-doc='Rscript -e "devtools::document()"'
alias rdev-load='Rscript -e "devtools::load_all()"'
alias rdev-install='Rscript -e "devtools::install()"'

# Linting and styling
alias rlint='Rscript -e "lintr::lint_dir()"'
alias rstyle='Rscript -e "styler::style_dir()"'

# ----------------------------------------------------------------------------
# load_r_template - Load an R template file
#
# This function loads template files from the R templates directory and
# optionally performs placeholder substitution.
#
# Arguments:
#   $1 - Template path (relative to templates/r/)
#
# Returns:
#   The template content, with placeholders substituted if provided
#
# Example:
#   load_r_template "analysis/analysis.Rmd.tmpl" > analysis.Rmd
# ----------------------------------------------------------------------------
load_r_template() {
    local template_path="$1"
    local template_file="/tmp/build-scripts/features/templates/r/${template_path}"

    if [ ! -f "$template_file" ]; then
        echo "Error: Template not found: $template_file" >&2
        return 1
    fi

    # No substitution needed for R templates (they use R's inline evaluation)
    command cat "$template_file"
}

# ----------------------------------------------------------------------------
# r-init-package - Create a new R package with best practices
#
# Arguments:
#   $1 - Package name (required)
#
# Example:
#   r-init-package mypackage
# ----------------------------------------------------------------------------
r-init-package() {
    if [ -z "$1" ]; then
        echo "Usage: r-init-package <package-name>"
        return 1
    fi

    local pkg_name="$1"
    echo "Creating new R package: $pkg_name"

    Rscript -e "
    usethis::create_package('$pkg_name')
    setwd('$pkg_name')
    usethis::use_git()
    usethis::use_mit_license()
    usethis::use_readme_rmd()
    usethis::use_testthat()
    usethis::use_package_doc()
    usethis::use_news_md()
    usethis::use_github_actions()
    usethis::use_github_actions_badge()
    cat('Package $pkg_name created successfully!\n')
    "
}

# ----------------------------------------------------------------------------
# r-init-analysis - Create a new analysis project
#
# Arguments:
#   $1 - Project name (required)
#
# Example:
#   r-init-analysis myanalysis
# ----------------------------------------------------------------------------
r-init-analysis() {
    if [ -z "$1" ]; then
        echo "Usage: r-init-analysis <project-name>"
        return 1
    fi

    local proj_name="$1"
    echo "Creating new analysis project: $proj_name"

    Rscript -e "
    usethis::create_project('$proj_name')
    setwd('$proj_name')

    # Create standard directories
    usethis::use_directory('data-raw')
    usethis::use_directory('data')
    usethis::use_directory('R')
    usethis::use_directory('outputs')
    usethis::use_directory('figures')

    # Initialize renv for reproducibility
    renv::init()

    # Create README
    usethis::use_readme_rmd()

    cat('Analysis project $proj_name created successfully!\n')
    "

    # Create initial analysis template using template loader
    load_r_template "analysis/analysis.Rmd.tmpl" > "${proj_name}/analysis.Rmd"
}

# ----------------------------------------------------------------------------
# r-render - Render R Markdown documents
#
# Arguments:
#   $1 - R Markdown file (required)
#   $2 - Output format (optional: html, pdf, word, all)
#
# Example:
#   r-render report.Rmd
#   r-render report.Rmd pdf
# ----------------------------------------------------------------------------
r-render() {
    if [ -z "$1" ]; then
        echo "Usage: r-render <file.Rmd> [format]"
        return 1
    fi

    local file="$1"
    local format="${2:-html_document}"

    if [ "$format" = "all" ]; then
        echo "Rendering $file to all formats..."
        Rscript -e "rmarkdown::render('$file', output_format = 'all')"
    else
        echo "Rendering $file to $format..."
        Rscript -e "rmarkdown::render('$file', output_format = '$format')"
    fi
}

# ----------------------------------------------------------------------------
# r-serve - Start a Shiny app or Plumber API
#
# Arguments:
#   $1 - App file or directory (optional, defaults to current directory)
#
# Example:
#   r-serve
#   r-serve app.R
#   r-serve myapp/
# ----------------------------------------------------------------------------
r-serve() {
    local app="${1:-.}"

    if [ -f "$app/app.R" ] || [ -f "$app/server.R" ]; then
        echo "Starting Shiny app in $app..."
        Rscript -e "shiny::runApp('$app', host = '0.0.0.0', port = 3838)"
    elif [ -f "$app" ] && grep -q "plumber" "$app"; then
        echo "Starting Plumber API from $app..."
        Rscript -e "pr <- plumber::plumb('$app'); pr\$run(host = '0.0.0.0', port = 8000)"
    else
        echo "No Shiny app or Plumber API found"
        return 1
    fi
}

# ----------------------------------------------------------------------------
# r-profile - Profile R code and visualize results
#
# Arguments:
#   $1 - R script to profile (required)
#
# Example:
#   r-profile analysis.R
# ----------------------------------------------------------------------------
r-profile() {
    if [ -z "$1" ]; then
        echo "Usage: r-profile <script.R>"
        return 1
    fi

    local script="$1"
    local prof_file="${script%.R}_profile.html"

    echo "Profiling $script..."
    Rscript -e "
    profvis::profvis({
        source('$script')
    }, prof_output = '$prof_file')
    cat('Profile saved to: $prof_file\n')
    "
}

# ----------------------------------------------------------------------------
# r-benchmark - Benchmark R code snippets
#
# Arguments:
#   $@ - R expressions to benchmark
#
# Example:
#   r-benchmark "1:1000000" "seq(1, 1000000)" "seq.int(1, 1000000)"
# ----------------------------------------------------------------------------
r-benchmark() {
    if [ $# -eq 0 ]; then
        echo "Usage: r-benchmark <expr1> <expr2> ..."
        return 1
    fi

    local exprs=""
    for expr in "$@"; do
        exprs="${exprs}${expr} = { $expr },"
    done
    exprs="${exprs%,}"  # Remove trailing comma

    Rscript -e "
    library(bench)
    result <- bench::mark(
        $exprs,
        check = FALSE,
        iterations = 100
    )
    print(result)
    "
}

# ----------------------------------------------------------------------------
# r-deps - Show package dependencies
#
# Arguments:
#   $1 - Package name or path (optional, defaults to current directory)
#
# Example:
#   r-deps
#   r-deps ggplot2
# ----------------------------------------------------------------------------
r-deps() {
    local pkg="${1:-.}"

    if [ -f "$pkg/DESCRIPTION" ] || [ "$pkg" = "." ]; then
        echo "Package dependencies for $pkg:"
        Rscript -e "desc::desc_get_deps('$pkg')"
    else
        echo "Dependencies of $pkg:"
        Rscript -e "
        deps <- tools::package_dependencies('$pkg', recursive = TRUE)
        if(length(deps[[1]]) > 0) {
            cat(paste(deps[[1]], collapse = '\n'), '\n')
        } else {
            cat('No dependencies found\n')
        }
        "
    fi
}


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
