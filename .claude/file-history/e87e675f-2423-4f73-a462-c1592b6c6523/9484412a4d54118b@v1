import torch

from vllm_ascend.core.kv_cache_interface import (
    compute_offload_sparse_c8_layout,
    make_offload_indexer_mla_spec,
    make_offload_main_mla_spec,
    offload_c8_indexer_page_size_bytes,
    offload_c8_main_page_size_bytes,
    offload_indexer_kernel_block_size,
    offload_indexer_pad_dim,
)
from vllm_ascend.utils import calc_split_factor

# DSV3.2 / GLM5.2 A3 dims
KV_LORA_RANK = 512
QK_ROPE_HEAD_DIM = 64
INDEX_HEAD_DIM = 128
INDEXER_PAD_DIM = offload_indexer_pad_dim(
    INDEX_HEAD_DIM, QK_ROPE_HEAD_DIM, KV_LORA_RANK
)  # 16
MLA_BLOCK_SIZE = 128
MAIN_BYTES_PER_TOKEN = (KV_LORA_RANK + QK_ROPE_HEAD_DIM) * 2  # bf16 main MLA: 1152
DSV32_C8_LAYOUT = compute_offload_sparse_c8_layout(
    KV_LORA_RANK,
    QK_ROPE_HEAD_DIM,
    INDEX_HEAD_DIM,
    torch.bfloat16,
    scale_dtype=torch.float16,
)


def test_offload_c8_main_page_size_bytes():
    page = offload_c8_main_page_size_bytes(
        MLA_BLOCK_SIZE,
        KV_LORA_RANK,
        QK_ROPE_HEAD_DIM,
        torch.bfloat16,
        c8_layout=DSV32_C8_LAYOUT,
    )
    # spec_0: 128 * (512 + 64 + 8) * 2 bytes (bf16)
    assert page == MLA_BLOCK_SIZE * (
        KV_LORA_RANK + QK_ROPE_HEAD_DIM + DSV32_C8_LAYOUT.kv_pad_dim_bf16_slots
    ) * 2


def test_offload_c8_indexer_page_size_bytes():
    page = offload_c8_indexer_page_size_bytes(
        MLA_BLOCK_SIZE,
        INDEX_HEAD_DIM,
        INDEXER_PAD_DIM,
        torch.float16,
    )
    # spec_1: 128 * (128 + 16 + 2) bytes (int8 idx + pad + fp16 scale)
    assert page == MLA_BLOCK_SIZE * (INDEX_HEAD_DIM + INDEXER_PAD_DIM + 2)


def test_offload_c8_page_ratio_is_eight_to_one():
    main_page = offload_c8_main_page_size_bytes(
        MLA_BLOCK_SIZE,
        KV_LORA_RANK,
        QK_ROPE_HEAD_DIM,
        torch.bfloat16,
        c8_layout=DSV32_C8_LAYOUT,
    )
    indexer_page = offload_c8_indexer_page_size_bytes(
        MLA_BLOCK_SIZE,
        INDEX_HEAD_DIM,
        INDEXER_PAD_DIM,
        torch.float16,
    )
    assert (
        main_page
        == indexer_page * DSV32_C8_LAYOUT.page_block_multiplier
    )


def test_offload_mla_spec_c8_page_bytes_per_token():
    spec = make_offload_main_mla_spec(
        block_size=MLA_BLOCK_SIZE,
        num_kv_heads=1,
        head_size=KV_LORA_RANK + QK_ROPE_HEAD_DIM,
        dtype=torch.bfloat16,
        kv_lora_rank=KV_LORA_RANK,
        qk_rope_head_dim=QK_ROPE_HEAD_DIM,
        index_head_dim=INDEX_HEAD_DIM,
        c8_unified_pool=True,
        scale_dtype=torch.float16,
    )
    assert spec.page_size_bytes == offload_c8_main_page_size_bytes(
        MLA_BLOCK_SIZE,
        KV_LORA_RANK,
        QK_ROPE_HEAD_DIM,
        torch.bfloat16,
        c8_layout=DSV32_C8_LAYOUT,
    )


def test_ascend_mla_offload_c8_page_bytes_per_token():
    spec = make_offload_indexer_mla_spec(
        block_size=MLA_BLOCK_SIZE,
        num_kv_heads=1,
        head_size=INDEX_HEAD_DIM + INDEXER_PAD_DIM,
        dtype=torch.bfloat16,
        cache_dtype_str="auto",
        index_head_dim=INDEX_HEAD_DIM,
        kv_lora_rank=KV_LORA_RANK,
        qk_rope_head_dim=QK_ROPE_HEAD_DIM,
        sparse_head_dim=(KV_LORA_RANK, QK_ROPE_HEAD_DIM, INDEX_HEAD_DIM),
        c8_unified_pool=True,
        scale_dtype=torch.float16,
    )
    assert spec.page_size_bytes == offload_c8_indexer_page_size_bytes(
        MLA_BLOCK_SIZE,
        INDEX_HEAD_DIM,
        INDEXER_PAD_DIM,
        torch.float16,
    )


def test_offload_c8_indexer_block_multiplier_matches_token_ratio():
    # 8 main blocks (128 tokens each) == 1 indexer block (1024 tokens)
    assert offload_indexer_kernel_block_size(
        MLA_BLOCK_SIZE,
        KV_LORA_RANK,
        INDEX_HEAD_DIM,
        c8_layout=DSV32_C8_LAYOUT,
    ) == MLA_BLOCK_SIZE * KV_LORA_RANK // INDEX_HEAD_DIM * 2


def test_offload_c8_pool_three_way_split_matches_main_page():
    """C8 offload allocates raw_k/raw_v/raw_scale from one pool page."""
    k_dim, v_dim = KV_LORA_RANK, QK_ROPE_HEAD_DIM
    pad_dim = DSV32_C8_LAYOUT.kv_pad_dim_bf16_slots
    factors = calc_split_factor([k_dim, v_dim, pad_dim])
    pool_bytes = offload_c8_main_page_size_bytes(
        MLA_BLOCK_SIZE,
        KV_LORA_RANK,
        QK_ROPE_HEAD_DIM,
        torch.bfloat16,
        c8_layout=DSV32_C8_LAYOUT,
    )
    k_bytes = int(pool_bytes // factors[0])
    v_bytes = int(pool_bytes // factors[1])
    scale_bytes = int(pool_bytes // factors[2])
    assert k_bytes + v_bytes + scale_bytes == pool_bytes
    assert k_bytes == MLA_BLOCK_SIZE * KV_LORA_RANK * 2
    assert v_bytes == MLA_BLOCK_SIZE * QK_ROPE_HEAD_DIM * 2
    assert scale_bytes == MLA_BLOCK_SIZE * pad_dim * 2


def test_compute_offload_sparse_c8_layout_dsv32_values():
    assert DSV32_C8_LAYOUT.kv_pad_dim_bf16_slots == 8
    assert DSV32_C8_LAYOUT.page_block_multiplier == 8
    assert DSV32_C8_LAYOUT.indexer_pad_dim == INDEXER_PAD_DIM
