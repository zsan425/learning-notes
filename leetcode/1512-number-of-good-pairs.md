# 1512. 好数对 (Number of Good Pairs)

> 难度：Easy ｜ 日期：2026-08-07 ｜ 解法：暴力 + 哈希

## 题目

统计满足 `i < j` 且 `nums[i] == nums[j]` 的下标对数。

## 解法一：暴力双重循环 — O(n²)

两层循环枚举所有 `i < j` 组合，相等则计数。时间 O(n²)，空间 O(1)。

## 解法二：哈希计数 — O(n)

```cpp
class Solution {
public:
    int numIdenticalPairs(vector<int>& nums) {
        unordered_map<int,int> m;
        int ans=0;
        for(int num:nums) {
            ans += m[num];   // 这个值已出现 m[num] 次 → 新增 m[num] 对
            ++m[num];
        }
        return ans;
    }
};
```

- 时间 O(n)，空间 O(n)

**关键点**：
- **先加后自增不能反**：第 k+1 次出现，能和前面 k 个同值各成一对
- `unordered_map::operator[]` 对不存在的 key **自动插入默认值 0** → 第一次 `m[num]` 是 0，不影响 ans
- 用到了 C++11：`unordered_map` + range-for（`for(int num : nums)`）
