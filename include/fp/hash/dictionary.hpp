#pragma once

#include "map.hpp"

namespace fp {
	template<typename Tkey, typename Tvalue, typename Hash = void, typename Equal = void>
	struct dictionary: public raii::hash_map<Tkey, Tvalue, Hash, Equal> {
		static_assert(!std::same_as<Tvalue, void>, "Dictionaries require a value to map to!");

		using super = raii::hash_map<Tkey, Tvalue, Hash, Equal>;
		using super::super;

		Tvalue& operator[](const Tkey& key) {
			if(!super::contains(key))
				return super::insert(key)->second;
			return super::find(key)->second;
		}
	};
}