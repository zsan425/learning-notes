# 0021. 合并两个有序链表 (Merge Two Sorted Lists)

> 难度：Easy ｜ 日期：2026-08-07 ｜ 解法：双指针 + dummy 虚拟头

## 思路

两个链表各持一个"当前指针"。谁的头小，就把谁接走，那个链表前进一格。某一边空了，就把另一边剩下的整串接上。

- 时间 O(n+m)，空间 O(1)

```cpp
ListNode* mergeTwoLists(ListNode* list1, ListNode* list2) {
    ListNode dummy(0);
    ListNode *tail = &dummy;
    while (list1 != nullptr && list2 != nullptr) {
        if (list1->val < list2->val) {
            tail->next = list1;
            list1 = list1->next;
        } else {
            tail->next = list2;
            list2 = list2->next;
        }
        tail = tail->next;
    }
    tail->next = list1 ? list1 : list2;
    return dummy.next;
}
```

## 关键点（本人在 08-07 实际踩过的坑）

- **dummy 虚拟头**：解决第一个节点的特例，让所有节点统一 `tail->next = ...`
- **链表是"接线"不是"填值"**：复用现成节点，全程不用 `new`、不用写 `val`
- **`&&` 不是 `||`**：两个都还在才循环，退出后 `tail->next = 剩余` 接上
- **`list1 = list1->next`**（移动指针）不是 `list1->next;`（无效果的语句）
- **悬垂指针**：不能 `return &dummy`（返回局部变量地址），要 `return dummy.next`
