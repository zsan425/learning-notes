# 0001. 两数之和 (Two Sum)

> 难度：Easy ｜ 日期：2026-08-04 ｜ 解法：C 暴力 + Python dict

## 题目

给定整数数组 `nums` 和一个目标值 `target`，找出和为目标值的两个数，返回它们的**下标**。
> 每个输入只有唯一解；不能使用同一元素两次。

## 解法一：C 暴力枚举 — O(n²)

**思路**：两层循环枚举所有 `i < j` 的组合，找到 `nums[i] + nums[j] == target` 即返回。

```c
int* twoSum(int* nums, int numsSize, int target, int* returnSize) {
    int* ans = (int*)malloc(2 * sizeof(int));
    *returnSize = 2;
    for (int i = 0; i < numsSize; i++) {
        for (int j = i + 1; j < numsSize; j++) {
            if (nums[i] + nums[j] == target) {
                ans[0] = i;
                ans[1] = j;
                return ans;
            }
        }
    }
    return NULL;
}
```

- 时间 O(n²)，空间 O(1)

## 解法二：Python 哈希表（dict）— O(n)

**思路**：遍历数组，**边查边存**。对每个数 `x`，查字典里有没有 `target - x`；有就返回，没有就把 `x` 存进字典（值 → 下标）。
把"找配对"从从头遍历 O(n) 变成 dict 的 O(1) 查询，总复杂度降到 O(n)。

```python
class Solution(object):
    def twoSum(self, nums, target):
        d = {}
        for i in range(len(nums)):
            x = nums[i]
            if (target - x) in d:
                return [i, d[target - x]]
            d[x] = i
```

- 时间 O(n)，空间 O(n)（字典最多存 n 个键）

## 关键点

- **dict 的 key 必须不可变**：数字 / 字符串 / 纯 tuple 可以，`(1, [2, 3])`（含 list）不行
- dict 存"值 → 下标"而不是"下标 → 值"，因为**题目要返回下标**
- 数组按"位置"查，dict 按"内容"查 —— 这正是 O(n²) → O(n) 的来源
- 下标顺序无所谓，LeetCode 都判对

## 踩坑记录（C 版）

1. **返回局部栈数组 = 悬垂指针**，题目要求 malloc，调用者 free()
2. `if` 后面不写花括号 → 只有下一句受 if 控制，后面的语句无条件执行
3. 漏设 `*returnSize` → 调用者不知道返回数组长度
4. VLA 大小用 `*returnSize` 有越界风险（传入可能是 0）
