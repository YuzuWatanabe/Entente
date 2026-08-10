FROM nvidia/cuda:11.8.0-cudnn8-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /workspace

# 必要なツールのインストール
RUN apt-get update && apt-get install -y \
    wget \
    gnupg2 \
    ca-certificates \
    git \
    build-essential \
    cmake \
    tshark \
    libpcap0.8-dev \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Monoのリポジトリを追加して、monoをインストール
RUN apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 3FA7E0328081BFF6A14DA29AA6A19B38D3D831EF \
    && echo "deb https://download.mono-project.com/repo/ubuntu stable-focal main" | tee /etc/apt/sources.list.d/mono-official-stable.list \
    && apt-get update && apt-get install -y mono-complete \
    && rm -rf /var/lib/apt/lists/*

# ローカルのSplitCap.exeをコンテナにコピー
COPY SplitCap.exe /workspace/SplitCap.exe

# Miniconda のインストール
RUN wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O /tmp/miniconda.sh \
    && bash /tmp/miniconda.sh -b -p /opt/conda \
    && rm /tmp/miniconda.sh
ENV PATH=/opt/conda/bin:$PATH

# Anaconda デフォルトチャンネルの利用規約(ToS)に同意
RUN conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main && \
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r

# Conda 環境の作成
RUN conda create -n anaconda3-cuda python=3.8 -y && \
    conda clean -a -y

# mkl / intel-openmp のバージョンをこの環境内で固定
# (pytorch=2.3 の pytorch チャンネル版ビルドは mkl==2021.4.0 の ABI に依存しており、
#  後続の conda install で mkl/intel-openmp が 2022+ に引き上げられると
#  `undefined symbol: iJIT_NotifyEvent` で import torch が失敗するため)
RUN mkdir -p /opt/conda/envs/anaconda3-cuda/conda-meta && \
    printf 'mkl==2021.4.0\nintel-openmp==2021.4.0\n' > /opt/conda/envs/anaconda3-cuda/conda-meta/pinned

# Conda 環境でパッケージのインストール
RUN /bin/bash -c "source /opt/conda/etc/profile.d/conda.sh && \
    conda activate anaconda3-cuda && \
    conda config --add channels defaults && \
    conda config --add channels conda-forge && \
    conda config --add channels pytorch && \
    conda config --add channels dglteam && \
    conda install -y cudatoolkit=11.8 && \
    conda install -y pytorch=2.3 torchvision torchaudio pytorch-cuda=11.8 -c pytorch -c nvidia && \
    conda install -y scipy numpy pandas matplotlib torchdata scikit-learn pydantic scapy networkx joblib tqdm pyyaml && \
    conda install -y dglteam/label/th23_cu118::dgl && \
    conda clean -a -y && \
    pip install pyshark pytorch_metric_learning wandb"

# PyTorch Geometric (Euler向け) のインストール
# torch 2.3 + CUDA 11.8 向けのビルド済みwheelを使用
RUN /bin/bash -c "source /opt/conda/etc/profile.d/conda.sh && \
    conda activate anaconda3-cuda && \
    pip install torch_geometric && \
    pip install pyg_lib torch_scatter torch_sparse torch_cluster torch_spline_conv -f https://data.pyg.org/whl/torch-2.3.0+cu118.html"

# SplitCapのヘルプを表示して動作確認
RUN mono /workspace/SplitCap.exe

# 環境変数の設定
ENV PATH=/opt/conda/envs/anaconda3-cuda/bin:$PATH
ENV LD_LIBRARY_PATH=/opt/conda/envs/anaconda3-cuda/lib:/usr/local/cuda/lib64
ENV CUDA_HOME=/usr/local/cuda
ENV DGLBACKEND=pytorch
ENV TSHARK_PATH=/usr/bin/tshark

# JupyterLab のインストール
RUN /bin/bash -c "source /opt/conda/etc/profile.d/conda.sh && \
    conda activate anaconda3-cuda && \
    conda install -y -c conda-forge jupyterlab ipywidgets && \
    pip install jupyterlab_widgets && \
    conda clean -a -y"

# mkl / intel-openmp を 2021.4.0 に強制固定し、壊れたシンボリックリンクを貼り直す
# (conda-meta/pinned だけでは解決できない依存関係で mkl が引き上げられた場合の保険。
#  最後に import torch を実行し、壊れたイメージがそのままビルド成功しないようにする)
RUN /bin/bash -c "source /opt/conda/etc/profile.d/conda.sh && \
    conda activate anaconda3-cuda && \
    pip install --no-deps --force-reinstall 'mkl==2021.4.0' 'intel-openmp==2021.4.0' && \
    cd /opt/conda/envs/anaconda3-cuda/lib && \
    for link in \$(find . -maxdepth 1 -xtype l -name '*.so*'); do \
        base=\$(basename \$link); \
        target=\$(find . -maxdepth 1 -name \"\${base}.*\" ! -xtype l | sort -V | tail -1); \
        if [ -n \"\$target\" ]; then ln -sf \$(basename \$target) \$base; fi; \
    done && \
    python -c 'import torch; print(\"torch import OK:\", torch.__version__, \"cuda:\", torch.cuda.is_available())'"

# ポート 8888 を開放
EXPOSE 8888

# コンテナは起動したまま維持する（VSCode Dev Containers でアタッチして開発するため）
CMD ["sleep", "infinity"]

