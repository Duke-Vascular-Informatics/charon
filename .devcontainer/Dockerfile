# =============================================================================
# Toolchain versions — MATCH YOUR SECURE ANALYTICS ENVIRONMENT
#
# The defaults below are the versions of R, Java and Python available in the
# secure environment this workspace was originally built for. Code developed
# here is later run there, so the dev container must use the versions YOUR
# secure environment provides. Change them in .env (R_VERSION, JAVA_VERSION,
# PYTHON_VERSION — see .env.example) rather than editing this file, then run
# "Dev Containers: Rebuild Container". After changing R_VERSION, also see
# docs/GETTING_STARTED.md ("Match the container to your secure environment")
# for the renv.lock steps.
#
#   R_VERSION      — must be a tag of rocker/r-ver (https://hub.docker.com/r/rocker/r-ver/tags)
#   JAVA_VERSION   — major version of an OpenJDK package available from apt on
#                    that rocker image's Ubuntu release (e.g. 8, 11, 17, 21)
#   PYTHON_VERSION — any CPython version uv can install (e.g. 3.10, 3.11, 3.12)
# =============================================================================
ARG R_VERSION=4.5.2
FROM rocker/r-ver:${R_VERSION}

# ARGs declared before FROM are not visible after it; re-declare the ones the
# build stages below need.
ARG JAVA_VERSION=17
ARG PYTHON_VERSION=3.12

# Install the JDK and system dependencies for common OHDSI and report-generation packages.
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-${JAVA_VERSION}-jdk-headless \
    libxml2-dev \
    libssl-dev \
    libcurl4-openssl-dev \
    libcairo2-dev \
    libfontconfig1-dev \
    libharfbuzz-dev \
    libfribidi-dev \
    libfreetype6-dev \
    libpng-dev \
    libtiff5-dev \
    libjpeg-dev \
    libgit2-dev \
    libx11-dev \
    libuv1-dev \
    git \
    openssh-client \
    curl \
    wget \
    unzip \
    xz-utils \
    cmake \
    pandoc \
    python3 \
    python3-pip \
    python3-venv \
    docker.io \
    && rm -rf /var/lib/apt/lists/*

# Make `python` resolve to python3 for scripts that use the bare name.
RUN ln -s /usr/bin/python3 /usr/local/bin/python

# Create a stable JAVA_HOME symlink that works on both amd64 and arm64.
RUN ARCH=$(dpkg --print-architecture) && \
    ln -s /usr/lib/jvm/java-${JAVA_VERSION}-openjdk-${ARCH} /usr/lib/jvm/java-current

ENV JAVA_HOME=/usr/lib/jvm/java-current
ENV PATH="$JAVA_HOME/bin:$PATH"

# Configure R to use the JDK installed above (rJava / DatabaseConnector need this).
RUN R CMD javareconf

# Accept the CRAN mirror URL from docker-compose build args (sourced from
# CRAN_MIRROR in .env). Falls back to the Duke mirror if not set.
ARG CRAN_MIRROR=https://archive.linux.duke.edu/cran/

# Write the mirror into Rprofile.site so every R package install — both
# at build time (renv below) and at runtime — uses the configured mirror.
RUN echo "options(repos = c(CRAN = \"${CRAN_MIRROR}\"))" \
      >> /usr/local/lib/R/etc/Rprofile.site

# Install renv for project-local dependency management, then pre-populate the
# bootstrap cache so renv/activate.R never needs to download renv from CRAN at
# container start time.  On restricted/proxied networks (university Wi-Fi) the
# bootstrap download fails with "cannot open URL" and aborts postCreateCommand.
# Copying the already-installed package into ~/.local/share/renv/bootstrap/...
# makes activate.R find it locally and skip the network request entirely.
RUN install2.r --error renv && \
    R -e " \
      ver      <- as.character(packageVersion('renv')); \
      rv       <- paste0('R-', R.version[['major']], '.', \
                         sub('\\\\..*', '', R.version[['minor']])); \
      platform <- R.version[['platform']]; \
      dest     <- file.path(path.expand('~'), '.local', 'share', 'renv', \
                            'bootstrap', rv, platform, 'renv', ver); \
      dir.create(dest, recursive = TRUE, showWarnings = FALSE); \
      src      <- find.package('renv'); \
      invisible(file.copy(list.files(src, full.names = TRUE), dest, recursive = TRUE)); \
      message('renv ', ver, ' cached to bootstrap path: ', dest) \
    "

# Install GitHub CLI (gh) so PRs can be created and merged from the terminal.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Install uv via pip — most network-portable method since python3-pip is already
# present from the apt layer above. Avoids pulling from astral.sh or ghcr.io,
# both of which fail on restricted/proxied university networks.
RUN pip3 install --no-cache-dir --break-system-packages uv
ENV PATH="/root/.local/bin:$PATH"

# Install a fully shared-library Python via uv.
# Ubuntu's system Python is NOT built with --enable-shared, so reticulate (R)
# cannot embed it.  uv downloads a standalone CPython build that includes
# libpython*.so, which is required for reticulate::use_virtualenv() to work.
RUN uv python install ${PYTHON_VERSION}

# Create a virtualenv at /opt/mlenv using the shared-library Python and install
# the ML stack needed to apply stored Python prediction models (e.g. a PLP Random Forest pickle).
# Match these library versions to your secure environment too, and to any model you load.
# scikit-learn is pinned to 1.2.2 for pickle compatibility with the stored model
# (which predates the missing_go_to_left field added in sklearn 1.3.0).
# numpy is pinned to <2.0 for ABI compatibility with sklearn 1.2.2 wheels.
RUN uv venv /opt/mlenv --python ${PYTHON_VERSION} && \
    uv pip install --python /opt/mlenv \
        pip \
        "scikit-learn==1.2.2" \
        "numpy<2.0" \
        pandas
