# Setting Up and Running `simple_target` Simulations on AlmaLinux 9

This guide walks you through setting up the required dependencies and environment on **AlmaLinux 9** to run the `simple_target` cocotb/Verilator simulation.

---

## 1. System Dependencies (DNF)

The `simple_target` test runs on **Verilator** and cocotb. Verilator compiles SystemVerilog into C++, requiring `make`, `gcc`, and `g++`. On AlmaLinux 9, Verilator is available via **EPEL** (which requires **CRB**).

Run the following commands:

```bash
# 1. Enable EPEL and CodeReady Builder (CRB)
sudo dnf install -y epel-release
sudo dnf config-manager --set-enabled crb

# 2. Install Verilator, C++ compiler, Make, and Python build headers
sudo dnf install -y make gcc gcc-c++ verilator git \
    zlib-devel bzip2-devel readline-devel sqlite-devel openssl-devel libffi-devel xz-devel patch
```

---

## 2. Python Virtual Environment

The repository includes helper scripts to bootstrap `pyenv` and set up the prepared virtual environment (`.venv`):

1. **Install pyenv** (run once):
   ```bash
   ./install.sh
   ```

2. **Activate and build the virtual environment**:
   ```bash
   . activate.sh
   ```

   This script:
   - Installs Python 3.11.0 using `pyenv`
   - Installs `uv` and runs `uv sync` to configure `.venv` with all needed dependencies (such as `cocotb`, `cocotbext-i3c`, and register generation tools)
   - Activates `.venv` in your current shell session

> [!NOTE]
> Whenever you start a new shell session to run simulations, simply re-run `. activate.sh` from the repository root.

---

## 3. Running the `simple_target` Simulation

Ensure the virtual environment is active (your prompt should show `(i3c-core)`).

### Direct invocation (recommended for development & debugging)
Run the simulation directly from the test directory:
```bash
make -C verification/cocotb/top/i3c_simple_target all
```

### Top-level test runner
Alternatively, run the test using the repository's top-level make target:
```bash
TEST=i3c_simple_target make test
```

### Cleaning build artifacts
To clean previous simulation builds:
```bash
make -C verification/cocotb/top/i3c_simple_target clean
```

