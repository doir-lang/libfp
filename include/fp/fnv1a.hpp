#pragma once

#include "string.hpp"
#include "fnv1a.h"
#include <cstdint>

namespace fp { inline namespace hash {
	struct fnv1a_base {
		static inline uint64_t hash(fp::view<std::byte> view) noexcept {
			return fp_fnv1a_hash((fp_view(uint8_t))view);
		}
	};

	template<typename T>
	struct fnv1a : public fnv1a_base {
		size_t operator()(const T& v) const noexcept {
			return hash({(std::byte*)&v, sizeof(T)});
		}
	};

	template<>
	struct fnv1a<fp::string_view> : public fnv1a_base {
		size_t operator()(const fp::string_view v) const noexcept {
			return hash({(std::byte*)v.data(), v.size()});
		}
	};

	template<>
	struct fnv1a<fp::string> : public fnv1a_base {
		size_t operator()(const fp::string v) const noexcept {
			return hash({(std::byte*)v.raw, v.size()});
		}
	};

	template<>
	struct fnv1a<fp::raii::string> : public fnv1a_base {
		size_t operator()(const fp::string v) const noexcept {
			return hash({(std::byte*)v.raw, v.size()});
		}
	};
}}