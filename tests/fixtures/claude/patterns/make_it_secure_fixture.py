# Fixture for loop-make-it-secure patterns.sh

import subprocess

def run_command(cmd):
    subprocess.call(cmd, shell=True)

blacklist = ["admin", "root"]
