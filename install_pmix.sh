# Install build dependencies
sudo apt install -y \
    build-essential wget \
    libssl-dev \
    libhwloc-dev \
    libevent-dev \
    libmunge-dev

# Download and build PMIx
cd /tmp
wget https://github.com/openpmix/openpmix/releases/download/v4.2.9/pmix-4.2.9.tar.gz
tar -xzf pmix-4.2.9.tar.gz
cd pmix-4.2.9
./configure \
    --prefix=/usr/local/pmix \
    --with-munge \
    --with-libevent \
    --with-hwloc
make -j$(nproc)
sudo make install

# Add to library path
echo "/usr/local/pmix/lib" | sudo tee /etc/ld.so.conf.d/pmix.conf
sudo ldconfig
