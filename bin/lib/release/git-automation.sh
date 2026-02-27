#!/bin/bash
# Git automation functions for release.sh
#
# Description:
#   Handles git commit, tag, push, and GitHub release creation
#   during the automated release process.
#
# Expected variables from parent script:
#   AUTO_COMMIT, AUTO_TAG, AUTO_PUSH, AUTO_GITHUB_RELEASE
#   NEW_VERSION, NON_INTERACTIVE
#   RED, GREEN, BLUE, YELLOW, NC
#
# Usage:
#   source "${BIN_DIR}/lib/release/git-automation.sh"
#   perform_git_automation "$NEW_VERSION"

perform_git_automation() {
    local new_version="$1"

    # Check if we're in a git repository
    if [ ! -d .git ]; then
        echo -e "${YELLOW}Not a git repository - manual commit required${NC}"
        return 0
    fi

    # Check for uncommitted changes
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo -e "${YELLOW}Note: You have uncommitted changes${NC}"
        echo ""
    fi

    # Auto-commit if requested
    if [ "$AUTO_COMMIT" = "true" ]; then
        echo ""
        echo -e "${BLUE}Auto-committing changes...${NC}"
        git add -A
        git commit -m "chore(release): Release version $new_version"
        echo -e "${GREEN}✓${NC} Changes committed"
    fi

    # Reorder: push first, then tag (prevents tagging commits that fail validation)
    if [ "$AUTO_PUSH" = "true" ]; then
        echo ""
        echo -e "${BLUE}Pushing changes to remote...${NC}"

        # Get current branch
        local current_branch
        current_branch=$(git rev-parse --abbrev-ref HEAD)

        # Push branch first (this runs pre-push validation hook)
        if ! git push origin "$current_branch"; then
            echo -e "${RED}✗ Failed to push branch${NC}"
            echo "Pre-push validation failed. Fix the issues and try again."
            exit 1
        fi
        echo -e "${GREEN}✓${NC} Pushed branch: $current_branch"

        # Only create and push tag if branch push succeeded
        if [ "$AUTO_TAG" = "true" ]; then
            echo ""
            echo -e "${BLUE}Creating git tag v$new_version...${NC}"
            git tag -a "v$new_version" -m "Release version $new_version"
            echo -e "${GREEN}✓${NC} Tag created"

            if ! git push origin "v$new_version"; then
                echo -e "${RED}✗ Failed to push tag${NC}"
                exit 1
            fi
            echo -e "${GREEN}✓${NC} Pushed tag: v$new_version"
        fi
    else
        # Not auto-pushing - create tag locally if requested
        if [ "$AUTO_TAG" = "true" ]; then
            echo ""
            echo -e "${BLUE}Creating git tag v$new_version...${NC}"
            git tag -a "v$new_version" -m "Release version $new_version"
            echo -e "${GREEN}✓${NC} Tag created"
        fi
    fi

    # Auto-create GitHub release if requested
    if [ "$AUTO_GITHUB_RELEASE" = "true" ]; then
        echo ""
        echo -e "${BLUE}Creating GitHub release...${NC}"

        # Check if gh is installed
        if ! command -v gh >/dev/null 2>&1; then
            echo -e "${YELLOW}Warning: gh CLI not found, skipping GitHub release${NC}"
            echo "Install gh CLI: https://cli.github.com/"
        else
            # Switch to config auth if GITHUB_TOKEN is set
            if [ -n "${GITHUB_TOKEN:-}" ]; then
                unset GITHUB_TOKEN
                gh auth switch 2>/dev/null || true
            fi

            # Generate release notes from CHANGELOG
            local release_notes
            release_notes=$(./bin/generate-release-notes.sh "$new_version" 2>/dev/null || echo "See [CHANGELOG.md](https://github.com/joshjhall/containers/blob/v$new_version/CHANGELOG.md) for details.")

            # Create release
            if gh release create "v$new_version" \
                --title "Release v$new_version" \
                --notes "$release_notes"; then
                echo -e "${GREEN}✓${NC} GitHub release created: https://github.com/joshjhall/containers/releases/tag/v$new_version"
            else
                echo -e "${YELLOW}Warning: Failed to create GitHub release${NC}"
                echo "You can create it manually at: https://github.com/joshjhall/containers/releases/new?tag=v$new_version"
            fi
        fi
    fi

    # Show next steps if not fully automated
    if [ "$AUTO_COMMIT" = "false" ] || [ "$AUTO_TAG" = "false" ] || [ "$AUTO_PUSH" = "false" ]; then
        echo ""
        echo "To complete the release, run:"
        if [ "$AUTO_COMMIT" = "false" ]; then
            echo -e "  ${BLUE}git add -A${NC}"
            echo -e "  ${BLUE}git commit -m \"chore(release): Release version $new_version\"${NC}"
        fi
        if [ "$AUTO_TAG" = "false" ]; then
            echo -e "  ${BLUE}git tag -a v$new_version -m \"Release version $new_version\"${NC}"
        fi
        if [ "$AUTO_PUSH" = "false" ]; then
            local current_branch
            current_branch=$(git rev-parse --abbrev-ref HEAD)
            echo -e "  ${BLUE}git push origin $current_branch${NC}"
            echo -e "  ${BLUE}git push origin v$new_version${NC}"
        fi
        if [ "$AUTO_GITHUB_RELEASE" = "false" ]; then
            echo ""
            echo "Or use automation flags:"
            echo -e "  ${BLUE}$0 --full-auto $*${NC}  # Fully automated release"
        fi
        echo ""
        echo "The tag push will trigger GitHub Actions to:"
        echo "  - Build all container variants"
        echo "  - Push images to ghcr.io/joshjhall/containers"
    fi
}
