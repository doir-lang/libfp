#include "../pointer.hpp"
#include "../string.hpp"
#include <cstddef>

namespace fp { inline namespace hash {
	struct fnv1a_base {
		static uint64_t hash(fp::view<std::byte> view) noexcept {
			constexpr uint64_t FNV_OFFSET_BASIS = 14695981039346656037u;
			constexpr uint64_t FNV_PRIME = 1099511628211u;

			uint64_t hash = FNV_OFFSET_BASIS;
			for(size_t i = view.size(); i--; ) {
				hash ^= (uint64_t)view.data()[i];
				hash *= FNV_PRIME;
			}
			return hash;
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