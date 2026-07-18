# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright contributors to the vLLM project

from dataclasses import dataclass, field

import torch
from typing_extensions import Self
from vllm.config import VllmConfig
from vllm.utils.math_utils import cdiv
from vllm.utils.torch_utils import get_dtype_size
from vllm.v1.core.single_type_kv_cache_manager import SlidingWindowManager
from vllm.v1.kv_cache_interface import AttentionSpec, FullAttentionSpec, MLAAttentionSpec, SlidingWindowMLASpec
from vllm.v1.kv_cache_spec_registry import KVCacheSpecRegistry

from vllm_ascend.core.single_type_kv_cache_manager import CompressAttentionManager, OffloadMLAAttentionManager
from vllm_ascend.utils import AscendDeviceType, get_ascend_device_type


def _get_c8_k_cache_dtype() -> torch.dtype:
    return torch.float8_e4m3fn if get_ascend_device_type() == AscendDeviceType.A5 else torch.int8


def _get_c8_k_scale_cache_dtype() -> torch.dtype:
    return torch.float32 if get_ascend_device_type() == AscendDeviceType.A5 else torch.float16


# GLM5.2 / DSV3.2 SFA offload + LIC8 unified pool layout (spec_0 / spec_1).
# Per-token byte layout (DSV3.2 / GLM5.2 A3 example):
#   spec_0: (k 512 + v 64 + pad 8) * 2 bytes (bf16)
#   spec_1: (idx 128 + pad 16 + scale 2) * 1 byte (int8 byte-mix accounting)
# scale is physically 1 fp16 element (2 bytes); it is counted as 2 in the
# spec_1 formula so page_bytes matches the int8 + pad byte mix.
# block_size=128 → page_bytes spec_0:spec_1 == 8:1 for unify_kv_cache_spec_page_size;
# indexer kernel block_size = page_block_multiplier * main block_size (1024 tokens).
# Pad and page_block_multiplier are derived from model dims via
# ``compute_offload_sparse_c8_layout`` (not hardcoded).


def offload_indexer_pad_dim(
    index_head_dim: int,
    qk_rope_head_dim: int,
    kv_lora_rank: int,
) -> int:
    return index_head_dim * qk_rope_head_dim // kv_lora_rank


@dataclass(frozen=True)
class OffloadSparseC8Layout:
    """Derived C8 unified-pool layout for SFA offload."""

    indexer_pad_dim: int
    kv_pad_dim_bf16_slots: int
    page_block_multiplier: int
    main_bytes_per_token: int
    indexer_bytes_per_token: int


def compute_offload_sparse_c8_layout(
    kv_lora_rank: int,
    qk_rope_head_dim: int,
    index_head_dim: int,
    main_dtype: torch.dtype,
    *,
    scale_dtype: torch.dtype | None = None,
) -> OffloadSparseC8Layout:
    """Derive spec_0/spec_1 page layout from model dimensions.

    ``page_block_multiplier`` enforces the main:indexer page ratio required by
    ``unify_kv_cache_spec_page_size``. ``kv_pad_dim_bf16_slots`` pads spec_0 so
    its per-token byte count fills that ratio against the spec_1 byte-mix layout.
    """
    scale_dtype = scale_dtype or _get_c8_k_scale_cache_dtype()
    indexer_pad_dim = offload_indexer_pad_dim(
        index_head_dim, qk_rope_head_dim, kv_lora_rank
    )
    indexer_bytes_per_token = offload_c8_indexer_bytes_per_token(
        index_head_dim, indexer_pad_dim, scale_dtype
    )
    dtype_size = get_dtype_size(main_dtype)
    non_c8_main_bytes = (kv_lora_rank + qk_rope_head_dim) * dtype_size
    page_block_multiplier = 2 * kv_lora_rank // index_head_dim
    main_bytes_per_token = page_block_multiplier * indexer_bytes_per_token
    kv_pad_dim_bf16_slots = (
        main_bytes_per_token - non_c8_main_bytes
    ) // dtype_size
    assert kv_pad_dim_bf16_slots >= 0
    assert main_bytes_per_token == offload_c8_main_bytes_per_token(
        kv_lora_rank,
        qk_rope_head_dim,
        main_dtype,
        kv_pad_dim_bf16_slots=kv_pad_dim_bf16_slots,
    )
    assert main_bytes_per_token % indexer_bytes_per_token == 0
    assert (
        main_bytes_per_token // indexer_bytes_per_token
        == page_block_multiplier
    )
    return OffloadSparseC8Layout(
        indexer_pad_dim=indexer_pad_dim,
        kv_pad_dim_bf16_slots=kv_pad_dim_bf16_slots,
        page_block_multiplier=page_block_multiplier,
        main_bytes_per_token=main_bytes_per_token,
        indexer_bytes_per_token=indexer_bytes_per_token,
    )


def offload_c8_main_bytes_per_token(
    kv_lora_rank: int,
    qk_rope_head_dim: int,
    dtype: torch.dtype,
    *,
    kv_pad_dim_bf16_slots: int,
) -> int:
    dtype_size = get_dtype_size(dtype)
    return (
        kv_lora_rank * dtype_size
        + qk_rope_head_dim * dtype_size
        + kv_pad_dim_bf16_slots * dtype_size
    )


def offload_main_kv_head_dims_for_pool_split(
    kv_lora_rank: int,
    qk_rope_head_dim: int,
    *,
    c8_layout: OffloadSparseC8Layout | None = None,
) -> list[int]:
    dims = [kv_lora_rank, qk_rope_head_dim]
    if c8_layout is not None:
        dims.append(c8_layout.kv_pad_dim_bf16_slots)
    return dims


def offload_indexer_kernel_block_size(
    mla_block_size: int,
    kv_lora_rank: int,
    index_head_dim: int,
    *,
    c8_layout: OffloadSparseC8Layout | None = None,
) -> int:
    if c8_layout is not None:
        return mla_block_size * c8_layout.page_block_multiplier
    return mla_block_size * kv_lora_rank // index_head_dim


def offload_c8_indexer_bytes_per_token(
    index_head_dim: int,
    indexer_pad_dim: int,
    scale_dtype: torch.dtype,
) -> int:
    return (
        index_head_dim * get_dtype_size(torch.int8)
        + indexer_pad_dim
        + get_dtype_size(scale_dtype)
    )


def _offload_page_size_bytes(
    block_size: int,
    num_kv_heads: int,
    page_bytes_per_token: int,
) -> int:
    return block_size * num_kv_heads * page_bytes_per_token


def offload_c8_main_page_size_bytes(
    block_size: int,
    kv_lora_rank: int,
    qk_rope_head_dim: int,
    dtype: torch.dtype,
    *,
    num_kv_heads: int = 1,
    c8_layout: OffloadSparseC8Layout | None = None,
    index_head_dim: int | None = None,
    scale_dtype: torch.dtype | None = None,
) -> int:
    if c8_layout is None:
        assert index_head_dim is not None
        c8_layout = compute_offload_sparse_c8_layout(
            kv_lora_rank,
            qk_rope_head_dim,
            index_head_dim,
            dtype,
            scale_dtype=scale_dtype,
        )
    return _offload_page_size_bytes(
        block_size,
        num_kv_heads,
        c8_layout.main_bytes_per_token,
    )


def offload_c8_indexer_page_size_bytes(
    block_size: int,
    index_head_dim: int,
    indexer_pad_dim: int,
    scale_dtype: torch.dtype,
    *,
    num_kv_heads: int = 1,
) -> int:
    """Indexer-group page size for C8 offload unified pool (spec_1).

    Byte-mix per token: ``index_head_dim`` int8 bytes + ``indexer_pad_dim``
    pad bytes + ``get_dtype_size(scale_dtype)`` for one scale element (e.g. 2
    bytes for fp16). The sum is not multiplied by a single dtype size; each
    term is already in bytes so spec_1 can 8:1-unify with spec_0.
    """
    return _offload_page_size_bytes(
        block_size,
        num_kv_heads,
        offload_c8_indexer_bytes_per_token(
            index_head_dim, indexer_pad_dim, scale_dtype
        ),
    )


@dataclass(frozen=True, kw_only=True)
class AscendMLAAttentionSpec(MLAAttentionSpec):
    """MLAAttentionSpec extended to support DSA models, with optional Sparse C8 support.

    When Sparse C8 is enabled, the KV cache tuple changes from
    (kv_cache[0]: bfloat16, kv_cache[1]: bfloat16, kv_cache[2]: bfloat16)
    to
    (kv_cache[0]: bfloat16, kv_cache[1]: bfloat16, kv_cache[2]: int8, kv_cache[3]: float16).

    The semantic meaning of each native KV cache entry is as follows:
    1. kv_cache[0] stores kv_lora.
    2. kv_cache[1] stores k_rope.
    3. kv_cache[2] stores the key tensor from the indexer module.
    4. kv_cache[3] stores the key scale tensor from the indexer module,
       and exists only when Sparse C8 is enabled.

    With SFA KV-quant sparse attention, kv_lora, k_rope, and per-tile
    quantization scales are packed into kv_cache[0]. The resulting cache is
    (packed_kv, indexer_k) or (packed_kv, indexer_k, indexer_scale) when
    Sparse C8 indexer cache is enabled.

    The main changes are as follows:
    1. The key tensor from the indexer module stored in kv_cache[2] is
       converted from bf16 to int8 to reduce memory usage. It is then
       processed with int8 precision in Lightning_indexer computation
       to improve computational efficiency.
    2. The quantization scale of the key tensor in the indexer module
       must also be stored for the Lightning_indexer_quant operator,
       and is therefore saved in kv_cache[3].
    """

    scale_dim: int = 0
    scale_dtype: torch.dtype = torch.int8
    sparse_head_dim: tuple[int, ...] | None = None
    cache_sparse_c8: bool = False
    # SFA offload + LIC8 unified pool: precomputed bytes/token for page_size.
    # When set, page_size_bytes = block_size * num_kv_heads * page_bytes_per_token.
    page_bytes_per_token: int | None = None
    c8_k_cache_dtype: torch.dtype = field(default_factory=_get_c8_k_cache_dtype)
    c8_k_scale_cache_dtype: torch.dtype = field(default_factory=_get_c8_k_scale_cache_dtype)
    sfa_dcp_replicated_indexer_size: int = 1

    @property
    def page_size_bytes(self) -> int:
        if self.page_bytes_per_token is not None:
            return _offload_page_size_bytes(
                self.block_size,
                self.num_kv_heads,
                self.page_bytes_per_token,
            )

        if self.cache_sparse_c8:
            assert self.sparse_head_dim is not None
            assert len(self.sparse_head_dim) == 3
            num_heads_per_page = self.block_size * self.num_kv_heads

            ckv_head_dim, qk_rope_head_dim, index_head_dim = self.sparse_head_dim
            assert qk_rope_head_dim == 0

            ckv_bytes = num_heads_per_page * ckv_head_dim * get_dtype_size(self.c8_k_cache_dtype)
            qli_bytes = num_heads_per_page * index_head_dim * get_dtype_size(self.c8_k_cache_dtype)
            qli_scale_bytes = (
                num_heads_per_page * self.sfa_dcp_replicated_indexer_size * get_dtype_size(self.c8_k_scale_cache_dtype)
                if index_head_dim > 0
                else 0
            )
            return ckv_bytes + qli_bytes + qli_scale_bytes

        return (
            self.block_size
            * self.num_kv_heads
            * (self.head_size * get_dtype_size(self.dtype) + self.scale_dim * get_dtype_size(self.scale_dtype))
        )

    @property
    def sparse_kv_cache_ratio(self) -> tuple[float, float | None, float | None, float | None]:
        """
        Compute the relative byte share of each KV cache entry.

        Returns:
            A tuple containing the ratios for:
            - kv_cache[0]
            - kv_cache[1]
            - kv_cache[2]
            - kv_cache[3] (None if Sparse C8 is disabled or Sparse C8 on A5 device)
        """

        assert self.sparse_head_dim is not None

        if self.cache_sparse_c8:
            ckv_head_dim, qk_rope_head_dim, index_k_head_dim = self.sparse_head_dim
            assert qk_rope_head_dim == 0

            ckv_virtual = ckv_head_dim * get_dtype_size(self.c8_k_cache_dtype)
            if index_k_head_dim == 0:
                return (
                    1.0,  # kv_cache[0]: ckv / packed_kv
                    None,  # kv_cache[1] does not exist without indexer cache
                    None,  # kv_cache[2] does not exist without indexer cache
                    None,  # kv_cache[3] does not exist for Sparse C8
                )

            qli_virtual = index_k_head_dim * get_dtype_size(self.c8_k_cache_dtype)
            scale_virtual = self.sfa_dcp_replicated_indexer_size * get_dtype_size(self.c8_k_scale_cache_dtype)
            total_virtual_head_dim = ckv_virtual + qli_virtual + scale_virtual

            return (
                total_virtual_head_dim / ckv_virtual,  # kv_cache[0]: ckv / packed_kv
                total_virtual_head_dim / qli_virtual,  # kv_cache[1]: qli
                total_virtual_head_dim / scale_virtual,  # kv_cache[2]: qli_scale
                None,  # kv_cache[3] does not exist for Sparse C8
            )

        return (
            self.head_size / self.sparse_head_dim[0],  # kv_cache[0]
            self.head_size / self.sparse_head_dim[1],  # kv_cache[1]
            (
                self.head_size / self.sparse_head_dim[2] if self.sparse_head_dim[2] > 0 else None
            ),  # kv_cache[2]  # kv_cache[2]
            None,  # kv_cache[3] does not exist
        )

    @classmethod
    def merge(cls, specs: list[Self]) -> Self:
        assert all(isinstance(spec, MLAAttentionSpec) for spec in specs), (
            "All attention layers in the same KV cache group must be MLAAttentionSpec."
        )
        layout_set = {
            (
                spec.block_size,
                spec.num_kv_heads,
                spec.head_size,
                spec.scale_dim,
                spec.scale_dtype,
                spec.sparse_head_dim,
                spec.dtype,
            )
            for spec in specs
        }
        assert len(layout_set) == 1, (
            "All attention layers in the same KV cache group must use the same KV cache layout."
        )
        cache_dtype_str_set = set(spec.cache_dtype_str for spec in specs)
        assert len(cache_dtype_str_set) == 1, (
            "All attention layers in the same KV cache group must use the same quantization method."
        )
        cache_sparse_c8_set = set(spec.cache_sparse_c8 for spec in specs)
        assert len(cache_sparse_c8_set) == 1, (
            "All attention layers in the same KV cache group must use the same sparse C8 setting."
        )
        sfa_dcp_replicated_indexer_size_set = set(spec.sfa_dcp_replicated_indexer_size for spec in specs)
        assert len(sfa_dcp_replicated_indexer_size_set) == 1, (
            "All attention layers in the same KV cache group must use the same SFA DCP replicated indexer size."
        )

        page_bytes_per_token_set = set(
            spec.page_bytes_per_token for spec in specs
        )
        assert len(page_bytes_per_token_set) == 1, (
            "All attention layers in the same KV cache group must use the same "
            "offload page_bytes_per_token setting."
        )
        return cls(
            block_size=specs[0].block_size,
            num_kv_heads=specs[0].num_kv_heads,
            head_size=specs[0].head_size,
            scale_dim=specs[0].scale_dim,
            scale_dtype=specs[0].scale_dtype,
            sparse_head_dim=specs[0].sparse_head_dim,
            dtype=specs[0].dtype,
            cache_dtype_str=cache_dtype_str_set.pop(),
            cache_sparse_c8=specs[0].cache_sparse_c8,
            sfa_dcp_replicated_indexer_size=sfa_dcp_replicated_indexer_size_set.pop(),
            page_bytes_per_token=specs[0].page_bytes_per_token,
        )

    def max_memory_usage_bytes(self, vllm_config: VllmConfig) -> int:
        max_model_len = vllm_config.model_config.max_model_len
        dcp_world_size = vllm_config.parallel_config.decode_context_parallel_size
        pcp_world_size = vllm_config.parallel_config.prefill_context_parallel_size
        # Note(hc): each dcp rank only need save
        # (max_model_len//dcp_world_size) tokens locally.
        if dcp_world_size * pcp_world_size > 1:
            max_model_len = cdiv(max_model_len, dcp_world_size * pcp_world_size)
        return cdiv(max_model_len, self.block_size * self.compress_ratio) * self.page_size_bytes


@dataclass(frozen=True, kw_only=True)
class AscendSlidingWindowMLASpec(SlidingWindowMLASpec):
    """Sliding window attention with MLA cache format."""

    cache_dtype_str: str | None = None
    # DeepseekV4-only: see MLAAttentionSpec.model_version.
    alignment: int | None = None  # Default to None for no padding.
    compress_ratio: int = 1
    model_version: str | None = None

    def __post_init__(self):
        pass

    @property
    def storage_block_size(self) -> int:
        return self.block_size

    @property
    def real_page_size_bytes(self) -> int:
        return self.storage_block_size * self.num_kv_heads * self.head_size * get_dtype_size(self.dtype)

    @classmethod
    def merge(cls, specs: list[Self]) -> Self:
        assert all(isinstance(spec, AscendSlidingWindowMLASpec) for spec in specs), (
            "All attention layers in the same KV cache group must be AscendSlidingWindowMLASpec."
        )
        cache_dtype_str_set = set(spec.cache_dtype_str for spec in specs)
        compress_ratio_set = set(spec.compress_ratio for spec in specs)
        model_version_set = set(spec.model_version for spec in specs)
        sliding_window_set = set(spec.sliding_window for spec in specs)
        assert (
            len(cache_dtype_str_set) == 1
            and len(compress_ratio_set) == 1
            and len(model_version_set) == 1
            and len(sliding_window_set) == 1
        ), (
            "All attention layers in the same KV cache group must use the same "
            "quantization method, compress ratio, model version and sliding "
            "window size."
        )
        return cls(
            block_size=specs[0].block_size,
            num_kv_heads=specs[0].num_kv_heads,
            head_size=specs[0].head_size,
            dtype=specs[0].dtype,
            page_size_padded=specs[0].page_size_padded,
            sliding_window=sliding_window_set.pop(),
            cache_dtype_str=cache_dtype_str_set.pop(),
            compress_ratio=compress_ratio_set.pop(),
            model_version=model_version_set.pop(),
        )


@dataclass(frozen=True, kw_only=True)
class OffloadMLAAttentionSpec(AttentionSpec):
    # SFA offload + LIC8 unified pool: precomputed bytes/token for page_size.
    page_bytes_per_token: int | None = None

    @property
    def page_size_bytes(self) -> int:
        if self.page_bytes_per_token is not None:
            return _offload_page_size_bytes(
                self.block_size,
                self.num_kv_heads,
                self.page_bytes_per_token,
            )
        return (
            self.block_size
            * self.num_kv_heads
            * self.head_size
            * get_dtype_size(self.dtype)
        )

    def max_memory_usage_bytes(self, vllm_config: VllmConfig) -> int:
        """The maximum possible memory usage of this KV cache in bytes.

        Feeds the startup must-fit check (_check_enough_kv_cache_memory) and the
        max_model_len auto-fit -- NOT num_blocks pool sizing, so changing this
        only relaxes the max_model_len limit, it does not shrink the pool.
        """
        ktc = vllm_config.kv_transfer_config
        if ktc is not None and ktc.kv_role == "kv_consumer":
            # PD D-side keeps only the MLA resident tail in HBM: the
            # remote-prefill prefix is null-padded, and completed decode blocks
            # are freed in-place after save. Reserve current partial + one
            # handoff block per request for the must-fit check.
            max_num_seqs = vllm_config.scheduler_config.max_num_seqs
            blocks_per_req = 2
            return blocks_per_req * max_num_seqs * self.page_size_bytes
        # Producer (P) or local offload (kv_both) or no kv-transfer: the prefix
        # transits HBM during prefill before being offloaded, so the peak is the
        # full max_model_len.
        max_model_len = vllm_config.model_config.max_model_len
        return cdiv(max_model_len, self.block_size) * self.page_size_bytes


def make_offload_main_mla_spec(
    *,
    block_size: int,
    num_kv_heads: int,
    head_size: int,
    dtype: torch.dtype,
    kv_lora_rank: int | None = None,
    qk_rope_head_dim: int | None = None,
    index_head_dim: int | None = None,
    c8_unified_pool: bool = False,
    scale_dtype: torch.dtype | None = None,
) -> OffloadMLAAttentionSpec:
    """Build main-MLA offload spec (spec_0).

    When ``c8_unified_pool`` is set, page accounting uses the shared
    ``page_bytes_per_token`` path (same formula as both offload groups).
    """
    page_bytes_per_token = None
    if c8_unified_pool:
        assert kv_lora_rank is not None and qk_rope_head_dim is not None
        assert index_head_dim is not None
        layout = compute_offload_sparse_c8_layout(
            kv_lora_rank,
            qk_rope_head_dim,
            index_head_dim,
            dtype,
            scale_dtype=scale_dtype,
        )
        page_bytes_per_token = layout.main_bytes_per_token
    return OffloadMLAAttentionSpec(
        block_size=block_size,
        num_kv_heads=num_kv_heads,
        head_size=head_size,
        dtype=dtype,
        page_bytes_per_token=page_bytes_per_token,
    )


def make_offload_indexer_mla_spec(
    *,
    block_size: int,
    num_kv_heads: int,
    head_size: int,
    dtype: torch.dtype,
    cache_dtype_str: str,
    index_head_dim: int,
    indexer_pad_dim: int | None = None,
    sparse_head_dim: tuple[int, ...] | None = None,
    c8_unified_pool: bool = False,
    scale_dtype: torch.dtype | None = None,
    kv_lora_rank: int | None = None,
    qk_rope_head_dim: int | None = None,
) -> AscendMLAAttentionSpec:
    """Build indexer offload spec (spec_1).

    Non-C8 uses nominal ``head_size`` (index + pad) with bf16 page accounting.
    C8 unified pool sets ``page_bytes_per_token`` to the spec_1 byte-mix layout.
    """
    if indexer_pad_dim is None:
        assert kv_lora_rank is not None and qk_rope_head_dim is not None
        indexer_pad_dim = offload_indexer_pad_dim(
            index_head_dim, qk_rope_head_dim, kv_lora_rank
        )
    page_bytes_per_token = None
    cache_sparse_c8 = False
    scale_dim = 0
    if c8_unified_pool:
        assert sparse_head_dim is not None
        scale_dtype = scale_dtype or _get_c8_k_scale_cache_dtype()
        page_bytes_per_token = offload_c8_indexer_bytes_per_token(
            index_head_dim, indexer_pad_dim, scale_dtype
        )
        cache_sparse_c8 = True
        scale_dim = indexer_pad_dim
    return AscendMLAAttentionSpec(
        block_size=block_size,
        num_kv_heads=num_kv_heads,
        head_size=head_size,
        dtype=dtype,
        cache_dtype_str=cache_dtype_str,
        sparse_head_dim=sparse_head_dim,
        scale_dim=scale_dim,
        cache_sparse_c8=cache_sparse_c8,
        page_bytes_per_token=page_bytes_per_token,
    )


def register_ascend_kv_cache_specs() -> None:
    KVCacheSpecRegistry.register(
        kvcache_spec_cls=AscendMLAAttentionSpec,
        manager_class=CompressAttentionManager,
        uniform_type_base_spec=FullAttentionSpec,
    )
    KVCacheSpecRegistry.register(
        kvcache_spec_cls=AscendSlidingWindowMLASpec,
        manager_class=SlidingWindowManager,
        uniform_type_base_spec=SlidingWindowMLASpec,
    )
    KVCacheSpecRegistry.register(
        OffloadMLAAttentionSpec,
        OffloadMLAAttentionManager,
        uniform_type_base_spec=OffloadMLAAttentionSpec,
    )
