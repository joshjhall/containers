#!/bin/bash
# Test script to regenerate /etc/bashrc.d/35-node-dev.sh

echo "=== Testing bashrc regeneration for node-dev ==="

# Backup existing file if it exists
if [ -f /etc/bashrc.d/35-node-dev.sh ]; then
    echo "Backing up existing file..."
    sudo cp /etc/bashrc.d/35-node-dev.sh /etc/bashrc.d/35-node-dev.sh.backup
fi

# Extract and run just the bashrc generation part
echo "Regenerating /etc/bashrc.d/35-node-dev.sh..."

sudo bash << 'SCRIPT_EOF'
cat > /etc/bashrc.d/35-node-dev.sh << 'EOF'

# ----------------------------------------------------------------------------
# Node.js Development Tool Aliases
# ----------------------------------------------------------------------------
# TypeScript shortcuts
alias tsc='typescript'
alias tsn='ts-node'
alias tsx='tsx'

# Testing shortcuts
alias j='jest'
alias jw='jest --watch'
alias jc='jest --coverage'
alias m='mocha'
alias vt='vitest'
alias vtw='vitest --watch'

# Linting shortcuts
alias esl='eslint'
alias eslf='eslint --fix'
alias pret='prettier --write'
alias pretc='prettier --check'

# Build shortcuts
alias wp='webpack'
alias wpw='webpack --watch'
alias vite='vite'
alias viteb='vite build'
alias vitep='vite preview'

# Process management
alias pm2s='pm2 status'
alias pm2l='pm2 logs'
alias pm2r='pm2 restart'
alias nmon='nodemon'

# ----------------------------------------------------------------------------
# node-new-project - Create a new Node.js project with TypeScript
#
# Arguments:
#   $1 - Project name (required)
#   $2 - Project type (optional: api, cli, lib, web, default: lib)
#
# Example:
#   node-new-project my-app api
# ----------------------------------------------------------------------------
node-new-project() {
    if [ -z "$1" ]; then
        echo "Usage: node-new-project <project-name> [type]"
        echo "Types: api, cli, lib, web"
        return 1
    fi

    local project_name="$1"
    local project_type="${2:-lib}"

    echo "Creating new Node.js project: $project_name (type: $project_type)"

    # Create project directory
    mkdir -p "$project_name"
    cd "$project_name"

    # Initialize package.json
    npm init -y

    # Create basic structure
    mkdir -p src tests docs

    # Install TypeScript and basic dev dependencies
    npm install --save-dev \
        typescript \
        @types/node \
        ts-node \
        tsx \
        eslint \
        @typescript-eslint/parser \
        @typescript-eslint/eslint-plugin \
        prettier \
        jest \
        @types/jest \
        ts-jest

    # Create tsconfig.json
    cat > tsconfig.json << 'TSCONFIG'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "commonjs",
    "lib": ["ES2022"],
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist", "tests"]
}
TSCONFIG

    # Create jest.config.js
    cat > jest.config.js << 'JESTCONFIG'
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  roots: ['<rootDir>/src', '<rootDir>/tests'],
  testMatch: ['**/__tests__/**/*.ts', '**/?(*.)+(spec|test).ts'],
  collectCoverageFrom: ['src/**/*.ts', '!src/**/*.d.ts'],
};
JESTCONFIG

    # Create .eslintrc.js
    cat > .eslintrc.js << 'ESLINTRC'
module.exports = {
  parser: '@typescript-eslint/parser',
  extends: [
    'eslint:recommended',
    'plugin:@typescript-eslint/recommended',
  ],
  parserOptions: {
    ecmaVersion: 2022,
    sourceType: 'module',
  },
  env: {
    node: true,
    jest: true,
  },
  rules: {
    '@typescript-eslint/explicit-function-return-type': 'off',
    '@typescript-eslint/no-explicit-any': 'warn',
  },
};
ESLINTRC

    # Create .prettierrc
    cat > .prettierrc << 'PRETTIERRC'
{
  "semi": true,
  "trailingComma": "all",
  "singleQuote": true,
  "printWidth": 100,
  "tabWidth": 2
}
PRETTIERRC

    # Create type-specific files
    case "$project_type" in
        api)
            npm install express cors helmet morgan compression
            npm install --save-dev @types/express @types/cors @types/morgan @types/compression
            cat > src/index.ts << 'APIINDEX'
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import morgan from 'morgan';
import compression from 'compression';

const app = express();
const PORT = process.env.PORT || 3000;

// Middleware
app.use(helmet());
app.use(cors());
app.use(compression());
app.use(morgan('combined'));
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Routes
app.get('/', (req, res) => {
  res.json({ message: 'API is running!' });
});

// Start server
app.listen(PORT, () => {
  console.log(`Server is running on port ${PORT}`);
});
APIINDEX
            ;;
        cli)
            npm install commander chalk ora
            npm install --save-dev @types/node
            cat > src/index.ts << 'CLIINDEX'
#!/usr/bin/env node
import { Command } from 'commander';
import chalk from 'chalk';

const program = new Command();

program
  .name('${project_name}')
  .description('CLI tool description')
  .version('0.1.0');

program
  .command('hello <name>')
  .description('Say hello')
  .action((name: string) => {
    console.log(chalk.green(`Hello, ${name}!`));
  });

program.parse();
CLIINDEX
            chmod +x src/index.ts
            ;;
        web)
            npm install --save-dev vite @vitejs/plugin-react
            cat > vite.config.ts << 'VITECONFIG'
import { defineConfig } from 'vite';

export default defineConfig({
  build: {
    outDir: 'dist',
  },
});
VITECONFIG
            ;;
        *)
            # Default library setup
            cat > src/index.ts << 'LIBINDEX'
export function hello(name: string): string {
  return `Hello, ${name}!`;
}
LIBINDEX
            ;;
    esac

    # Update package.json scripts
    npm pkg set scripts.build="tsc"
    npm pkg set scripts.dev="tsx watch src/index.ts"
    npm pkg set scripts.start="node dist/index.js"
    npm pkg set scripts.test="jest"
    npm pkg set scripts.test:watch="jest --watch"
    npm pkg set scripts.test:coverage="jest --coverage"
    npm pkg set scripts.lint="eslint src --ext .ts"
    npm pkg set scripts.lint:fix="eslint src --ext .ts --fix"
    npm pkg set scripts.format="prettier --write 'src/**/*.ts'"
    npm pkg set scripts.format:check="prettier --check 'src/**/*.ts'"

    # Create initial test
    cat > tests/index.test.ts << 'TESTFILE'
describe('Initial test', () => {
  it('should pass', () => {
    expect(true).toBe(true);
  });
});
TESTFILE

    echo "Project $project_name created successfully!"
    echo ""
    echo "Available scripts:"
    echo "  npm run dev          - Start development server"
    echo "  npm run build        - Build for production"
    echo "  npm test             - Run tests"
    echo "  npm run lint         - Lint code"
    echo "  npm run format       - Format code"
}

# ----------------------------------------------------------------------------
# node-test-all - Run all tests with coverage across different test runners
# ----------------------------------------------------------------------------
node-test-all() {
    echo "=== Running all test suites ==="

    # Check which test frameworks are available
    if [ -f "jest.config.js" ] || [ -f "jest.config.ts" ]; then
        echo "Running Jest tests..."
        jest --coverage
    fi

    if [ -f "vitest.config.js" ] || [ -f "vitest.config.ts" ]; then
        echo "Running Vitest tests..."
        vitest run --coverage
    fi

    if [ -f "mocha.opts" ] || [ -f ".mocharc.js" ] || [ -f ".mocharc.json" ]; then
        echo "Running Mocha tests..."
        mocha
    fi

    if [ -f "playwright.config.js" ] || [ -f "playwright.config.ts" ]; then
        echo "Running Playwright tests..."
        playwright test
    fi
}

# ----------------------------------------------------------------------------
# node-bundle-analyze - Analyze bundle size
# ----------------------------------------------------------------------------
node-bundle-analyze() {
    if [ -f "webpack.config.js" ]; then
        echo "Analyzing webpack bundle..."
        webpack-bundle-analyzer stats.json
    elif [ -f "vite.config.js" ] || [ -f "vite.config.ts" ]; then
        echo "Building with vite for analysis..."
        vite build --mode analyze
    else
        echo "No webpack or vite config found"
    fi
}

# ----------------------------------------------------------------------------
# node-deps-security - Check for security vulnerabilities
# ----------------------------------------------------------------------------
node-deps-security() {
    echo "=== Checking for security vulnerabilities ==="
    npm audit

    if command -v snyk &> /dev/null; then
        echo ""
        echo "Running Snyk security scan..."
        snyk test
    fi
}

# ----------------------------------------------------------------------------
# node-clean - Clean all build artifacts and caches
# ----------------------------------------------------------------------------
node-clean() {
    echo "=== Cleaning build artifacts and caches ==="

    # Remove common build directories
    rm -rf dist/ build/ .next/ out/ coverage/ .cache/ .parcel-cache/

    # Clean package manager caches
    npm cache clean --force

    if [ -f "yarn.lock" ]; then
        yarn cache clean
    fi

    if [ -f "pnpm-lock.yaml" ]; then
        pnpm store prune
    fi

    echo "Cleanup complete!"
}
EOF

chmod +x /etc/bashrc.d/35-node-dev.sh
SCRIPT_EOF

# Test syntax
echo ""
echo "Testing syntax of regenerated file..."
if bash -n /etc/bashrc.d/35-node-dev.sh 2>&1; then
    echo "✓ Syntax check passed!"
else
    echo "✗ Syntax check failed!"
    exit 1
fi

# Source it in a subshell to test
echo ""
echo "Testing sourcing the file..."
if bash -c "source /etc/bashrc.d/35-node-dev.sh && echo '✓ Sourcing successful!'"; then
    echo "✓ File can be sourced without errors"
else
    echo "✗ Sourcing failed!"
    exit 1
fi

echo ""
echo "=== Regeneration complete! ==="
echo "Now open a new terminal to test if the errors are gone."
echo ""
echo "To restore the backup (if needed):"
echo "  sudo cp /etc/bashrc.d/35-node-dev.sh.backup /etc/bashrc.d/35-node-dev.sh"
