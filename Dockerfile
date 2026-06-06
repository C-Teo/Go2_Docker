# ══════════════════════════════════════════════════════════════════════════════
# Run:
#   docker run \
#     -v ./config:/config \
#     -e CYCLONEDDS_URI=/config/cyclonedds.xml \
#     --network host \
#     go2
#
# Edit config/cyclonedds.xml on the host to change the network interface.
# ══════════════════════════════════════════════════════════════════════════════
# Build-time flags  (pass with --build-arg FLAG=true)
#
#   INSTALL_PY_SDK=true   pip-install unitree_sdk2_python (needs CYCLONEDDS_HOME)
#   BUILD_SDK=true        cmake-build & install the C++ unitree_sdk2
#   ADD_USER=true         create a non-root sudo user (default: unitree/1000/1000)
#     USERNAME=<name>       override the username          (default: unitree)
#     USER_UID=<uid>        override the UID               (default: 1000)
#     USER_GID=<gid>        override the GID               (default: 1000)
#
# Example:
#   docker build \
#     --build-arg INSTALL_PY_SDK=true \
#     --build-arg ADD_USER=true \
#     --build-arg USERNAME=teo \
#     -t go2 .
# ══════════════════════════════════════════════════════════════════════════════

ARG INSTALL_PY_SDK=false
ARG BUILD_SDK=false
ARG ADD_USER=false
ARG USERNAME=unitree
ARG USER_UID=1000
ARG USER_GID=1000

# ros:foxy already includes ros-base, rosdep, the entrypoint that sources
# /opt/ros/foxy/setup.bash, and the correct Ubuntu 20.04 base.
FROM ros:foxy

ARG INSTALL_PY_SDK
ARG BUILD_SDK
ARG ADD_USER
ARG USERNAME
ARG USER_UID
ARG USER_GID

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# ── Dependencies ───────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    # CycloneDDS RMW wrapper (pairs with RMW_IMPLEMENTATION env var)
    ros-foxy-rmw-cyclonedds-cpp \
    # Python package manager — required for unitree_sdk2_python install
    python3-pip \
    # C/C++ toolchain and build system
    build-essential \
    cmake \
    git \
    # Needed only when ADD_USER=true
    sudo \
    # Python C headers — required by some ROS package builds
    libpython3-dev \
    # C++ library headers — required by unitree_sdk2
    libeigen3-dev \
    libyaml-cpp-dev \
    libboost-all-dev \
    libspdlog-dev \
    libfmt-dev \
    # ROS 2 workspace build toolchain
    python3-colcon-common-extensions \
    python3-vcstool \
    python3-rosdep \
    # IDL interface generation — required by unitree_ros2
    ros-foxy-rosidl-generator-dds-idl \
    # Full desktop: rviz2, rqt, tf2 tools, ros2 CLI extras
    ros-foxy-desktop \
    && rm -rf /var/lib/apt/lists/*

ENV RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
# Mount config/cyclonedds.xml from the host at /config to override this path.
ENV CYCLONEDDS_URI=/config/cyclonedds.xml

# ── Clone Unitree repositories ─────────────────────────────────────────────────
RUN mkdir -p /opt/unitree && \
    git clone https://github.com/unitreerobotics/unitree_sdk2_python.git  /opt/unitree/unitree_sdk2_python && \
    git clone https://github.com/unitreerobotics/unitree_sdk2.git         /opt/unitree/unitree_sdk2 && \
    git clone https://github.com/unitreerobotics/unitree_ros2.git         /opt/unitree/unitree_ros2

# ── Build CycloneDDS from source (releases/0.10.x) ────────────────────────────
# The apt version is too old for both unitree_sdk2_python and unitree_ros2.
# One clone is shared between the standalone cmake install and the ROS workspace.
RUN git clone https://github.com/eclipse-cyclonedds/cyclonedds -b releases/0.10.x /opt/unitree/cyclonedds && \
    cmake -S /opt/unitree/cyclonedds \
          -B /opt/unitree/cyclonedds/build \
          -DCMAKE_INSTALL_PREFIX=/opt/unitree/cyclonedds/install && \
    cmake --build /opt/unitree/cyclonedds/build --target install --parallel "$(( $(nproc) / 4 > 0 ? $(nproc) / 4 : 1 ))"

ENV CYCLONEDDS_HOME=/opt/unitree/cyclonedds/install

# ── Build rmw_cyclonedds in the unitree_ros2 ROS workspace ────────────────────
RUN mkdir -p /opt/unitree/unitree_ros2/cyclonedds_ws/src && \
    git clone https://github.com/ros2/rmw_cyclonedds -b foxy \
        /opt/unitree/unitree_ros2/cyclonedds_ws/src/rmw_cyclonedds && \
    ln -s /opt/unitree/cyclonedds \
          /opt/unitree/unitree_ros2/cyclonedds_ws/src/cyclonedds && \
    bash -c "source /opt/ros/foxy/setup.bash && \
             cd /opt/unitree/unitree_ros2/cyclonedds_ws && \
             LD_LIBRARY_PATH=/opt/ros/foxy/lib:$LD_LIBRARY_PATH \
             colcon build --packages-select cyclonedds"

# ── Shell environment ──────────────────────────────────────────────────────────
RUN echo "source /opt/ros/foxy/setup.bash" >> /etc/bash.bashrc && \
    echo "source /opt/unitree/unitree_ros2/cyclonedds_ws/install/setup.bash" >> /etc/bash.bashrc

# ══════════════════════════════════════════════════════════════════════════════
# Optional build steps
# ══════════════════════════════════════════════════════════════════════════════

# INSTALL_PY_SDK — pip-install unitree_sdk2_python
RUN if [ "$INSTALL_PY_SDK" = "true" ]; then \
        pip3 install /opt/unitree/unitree_sdk2_python; \
    fi

# BUILD_SDK — cmake-build and install the C++ unitree_sdk2
RUN if [ "$BUILD_SDK" = "true" ]; then \
        cmake -S /opt/unitree/unitree_sdk2 \
              -B /opt/unitree/unitree_sdk2/build \
              -DCMAKE_BUILD_TYPE=Release && \
        cmake --build /opt/unitree/unitree_sdk2/build --parallel "$(( $(nproc) / 4 > 0 ? $(nproc) / 4 : 1 ))" && \
        cmake --install /opt/unitree/unitree_sdk2/build; \
    fi

# ADD_USER — create a non-root passwordless-sudo user
RUN if [ "$ADD_USER" = "true" ]; then \
        groupadd --gid "$USER_GID" "$USERNAME" && \
        useradd --uid "$USER_UID" --gid "$USER_GID" -m -s /bin/bash "$USERNAME" && \
        echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"$USERNAME" && \
        chmod 0440 /etc/sudoers.d/"$USERNAME"; \
    fi

CMD ["bash"]
