---
title: 'B-tree - Understanding how it works'
summary: 'Understanding how B-trees work'
authors:
  - 'Adewole Caleb'
date: '2026-08-15'
topics:
  - 'Database'
  - 'Engineering'
  - 'C'
type: 'Blog'
image: 'https://cdn.hashnode.com/uploads/covers/5f8c625883db9130bf5bc43a/56eeb554-83f7-471b-a75f-cf34eab2fe48.png'
---
I'm currently reading about B-trees in database internals and visualising the data structure with the help of a book library. I find myself particularly interested in just one specific book. This raises a question: how do I find this book? Interestingly, there is a catalogue that guides where to look, including the correct cabinet, shelf, and drawer.

*In my opinion, a library catalogue is usually more like a logical index, while a B-tree is the physical data structure used to implement that catalogue efficiently.*

Unlike the binary tree, which is really good as an in-memory data structure but poor as an on-disk data structure. B-trees are efficient due to the children and the keys relationship, as opposed to using a 2-3 node binary tree, since they are better on disk.

## Sorting And Trees

Binary search trees are usually rebalanced to ensure that the height is uniform and that the time it takes to locate information is logarithmic instead of maxing to a linear time. In the context of a database, they are not, however, good for on-disk storage, so B-trees are used instead, with natural support for sorted storage, insertions, and deletions of values

Keys inside B-trees are always sorted in order. This is because B-trees have a formula that allows them to properly perform insertion or search. This is quite similar to the binary tree, encouraging point or range queries during the search operation.

## What is a B-tree Node?

The puzzling part for me is the fact that I did not understand the meaning of the node of a B-tree, which is exactly why I am writing this. And it disturbs me at least during implementation.

Let's take a look at it by simplifying the definition.

1.  Root node - A node with no parent sitting at the top of the tree.
    
2.  Leaf node - A node sitting at the bottom layer with no kid nodes
    
3.  Internal node - Any node connected between the root and the leaf nodes
    
    ![](https://cdn.hashnode.com/uploads/covers/5f8c625883db9130bf5bc43a/56eeb554-83f7-471b-a75f-cf34eab2fe48.png align="center")
    

It is simple to understand, right? Let's represent it in C code and then talk about the other component allowed in the node.

```c
#include <stdio.h>
#include <stdlib.h>

/* ORDER = max keys per node; each node holds at most ORDER+1 child pointers */
#define ORDER 4
#define MIN_KEYS (ORDER / 2)

typedef struct BTreeNode
{
    int keys[ORDER];                       
    struct BTreeNode *children[ORDER + 1]; 
    int n;                                
    int is_leaf;                           
} BTreeNode;
```

In contrast to binary trees, where values are sorted during insertion by comparing new values with the current node to decide if they should go to the right or left subtree, B-trees use a different approach. Each new value is inserted into the appropriate range between a smaller and a larger key.

## Separator Keys

This appeared strange to me initially, since there are also child pointers. Why a key separator for a simple node? It later occurred to me that the keys are, in particular, the index entries that help in dividing trees into subtrees, which might be a subrange, depending on where the key lies.

A subtree is found by first locating a key range and following a corresponding pointer from a higher level to the lower level.

![](https://cdn.hashnode.com/uploads/covers/5f8c625883db9130bf5bc43a/25b58ca7-eaaa-48e1-9287-805c65b42c61.png align="center")

What sets this data structure apart is that it is built from bottom to top instead of from the top to the bottom, which is because it is built from the leaves to the top via splitting and merging of nodes

## Children Node

The children node of a B-tree usually has +1 more than the Keys in a node, since the range extends on both sides of a key. Using the image above, you will observe that having 3 keys corresponds to 4 ranges: *Ks < K1, K1 <= Ks < K2, K2 <= Ks < K3, and Ks >= K3.* So for a given node X, there exist N keys and N+1 pointers to child nodes.

```c
BTreeNode *create_node(int is_leaf)
{
    BTreeNode *node = (BTreeNode *)malloc(sizeof(BTreeNode));
    node->n = 0;
    node->is_leaf = is_leaf;
    for (int i = 0; i < ORDER + 1; i++)
        node->children[i] = NULL;
    return node;
}
```

Let's talk about supported operations with B-trees.

## Lookup Operation

```c
BTreeNode *btree_search(BTreeNode *node, int key, int *found_index) { 

    if (!node) return NULL;

    int i = 0;
    while (i < node->n && key > node->keys[i])
        i++;

    if (i < node->n && key == node->keys[i])
    {
        *found_index = i;
        return node;
    }

    if (node->is_leaf)
        return NULL;
    return btree_search(node->children[i], key, found_index);
}
```

We have clarified the importance of separator keys and child pointers to subtrees. Following the fundamental principle of a B-tree node, the lookup operation checks the range of the search key and follows the child pointer that best fits the criteria. Initially, it searches for a key close to the target and then recursively traverses down the tree, adhering to the rules until the correct match is found.

## The Splitter

Inserting a value into a B-tree appears straightforward since it involves finding the correct position for insertion. Using the lookup algorithm, we identify the spot, but the challenge arises when the target node is full, meaning it has no room left. In this case, we must split the node into two to accommodate the new value.

With this, when do we actually decide to use a splitter algorithm when the need arises?

1.  For leaf nodes:  
    If a node can hold up to N key-value pairs, and adding another pair exceeds this capacity, we must split the node.
    
2.  For non-leaf nodes:  
    If the node can accommodate up to N + 1 pointers, and adding another pointer exceeds this limit.
    
    To insert a key into a B-tree, if the key in the node is at maximum, then we need to split the node by creating a new one and attaching the first child pointer to the current node that is at its maximum, so we don't lose it while splitting in memory
    

```c
BTreeNode *btree_insert(BTreeNode *root, int key)
{
    if (root->n == ORDER)
    {
        BTreeNode *new_root = create_node(0);
        new_root->children[0] = root;
        split_child(new_root, 0);
        insert_nonfull(new_root, key);
        return new_root;
    }
    insert_nonfull(root, key);
    return root;
}
```

Splitting a node requires identifying a pivot point that corresponds to the number of keys in the node. Much like determining a pivot in a binary search algorithm, we use (N + 1) divided by 2 to locate the midpoint. But we must first create a new node that will hold the keys from the split node, then copy over the key and children into the new node from the pivot's right and then the actual inserted key over to the new node. Hence, we are promoting the key.

```c
static void split_child(BTreeNode *parent, int i)
{
 
    BTreeNode *full = parent->children[i];
    int mid = ORDER / 2;

    BTreeNode *right = create_node(full->is_leaf); 
    right->n = ORDER - mid - 1;      
    for (int j = 0; j < right->n; j++)
        right->keys[j] = full->keys[mid + 1 + j];
    if (!full->is_leaf)
    {
        for (int j = 0; j <= right->n; j++)
            right->children[j] = full->children[mid + 1 + j];
    }

    full->n = mid; 

    for (int j = parent->n; j > i; j--)
    {
        parent->children[j + 1] = parent->children[j];
        parent->keys[j] = parent->keys[j - 1];
    }

    parent->keys[i] = full->keys[mid]; 
    parent->children[i + 1] = right;
    parent->n++;
}
```

With this splitting algorithm, we can finally perform an insertion based on the two points listed above for non-leaf and leaf nodes.

```c
/*
 * Insert key into a node that is guaranteed NOT to be full (n < ORDER).
 *
 *   LEAF (has room):
 *     Shift keys right to open a slot, insert key.
 *
 *   INTERNAL:
 *     Find the child to descend into.
 *     If that child is full, split it first (which may redirect us
 *     to the new right sibling), then recurse.
 */
static void insert_nonfull(BTreeNode *node, int key)
{
    int i = node->n - 1;

    if (node->is_leaf)
    {
        while (i >= 0 && key < node->keys[i])
        {
            node->keys[i + 1] = node->keys[i];
            i--;
        }
        node->keys[i + 1] = key;
        node->n++;
        return;
    }

    while (i >= 0 && key < node->keys[i])
        i--;
    i++;

    if (node->children[i]->n == ORDER)
    {
        split_child(node, i);
        if (key > node->keys[i])
            i++;
    }
    insert_nonfull(node->children[i], key);
}
```

## The Merger

Deleting a node in a B-tree is just a simple lookup for a matching key to be removed. After which the key is removed, but the thing is that if the neighbouring node has fewer values than the minimum threshold, then the sibling nodes are merged due to an underflow of values in the Tree.

```c
static int get_predecessor(BTreeNode *node)
{
    while (!node->is_leaf)
        node = node->children[node->n];
    return node->keys[node->n - 1];
}

void btree_delete(BTreeNode *root, int key)
{
    if (!root)
        return;

    int i = 0;
    while (i < root->n && root->keys[i] < key)
        i++;

    if (root->is_leaf)
    {
        if (i < root->n && root->keys[i] == key)
        {
            for (; i < root->n - 1; i++)
                root->keys[i] = root->keys[i + 1]; 
            root->n--;
        }
        return;
    }

    if (i < node->n && node->keys[i] == key)
    {
        int predecessor = get_predecessor(node->children[i]);
        node->keys[i] = predecessor;
        btree_delete(node->children[i], predecessor);

        if (node->children[i]->n < MIN_KEYS)
            rebalance_children(node, i);

        return;
    }

    btree_delete(root->children[i], key);
    if (root->children[i]->n < MIN_KEYS)
        rebalance_children(root, i);
}
```

Meaning that when there is an underflow, two adjacent nodes have a common parent and their contents fit into a single node, their contents should be merged (concatenated); if their contents do not fit into a single node, keys are redistributed between them to restore balance.

Nodes are merged only if the following conditions are met:

1\. For non-leaf nodes: If a node can accommodate up to N + 1 pointers, and the total number of pointers in two neighbouring nodes is less than or equal to N + 1.

2\. For leaf nodes: If a node can hold up to N key-value pairs, and the combined number of key-value pairs in two neighbouring nodes is less than or equal to N.

Satisfying these conditions will result in a code like this for the merge functionality.

```c
void rebalance_children(BTreeNode *parent, int i)
{
    BTreeNode *child = parent->children[i];
    BTreeNode *left = (i > 0) ? parent->children[i - 1] : NULL;
    BTreeNode *right = (i < parent->n) ? parent->children[i + 1] : NULL;

    if (left && left->n > MIN_KEYS)
    {
        for (int j = child->n; j > 0; j--)
            child->keys[j] = child->keys[j - 1];
        for (int j = child->n + 1; j > 0; j--)
            child->children[j] = child->children[j - 1];

        child->keys[0] = parent->keys[i - 1];
        child->children[0] = left->children[left->n];
        child->n++;

        parent->keys[i - 1] = left->keys[left->n - 1];
        left->n--;
        return;
    }

    if (right && right->n > MIN_KEYS)
    {
        child->keys[child->n] = parent->keys[i];
        child->children[child->n + 1] = right->children[0]; 
        child->n++;

        parent->keys[i] = right->keys[0];

        for (int j = 0; j < right->n - 1; j++)
            right->keys[j] = right->keys[j + 1];
        for (int j = 0; j < right->n; j++)
            right->children[j] = right->children[j + 1];
        right->n--;
        return;
    }

    BTreeNode *merged;
    BTreeNode *absorbed;
    int sep;

    if (left)
    {
        merged = left;
        absorbed = child;
        sep = i - 1;
    }
    else
    {
        merged = child;
        absorbed = right;
        sep = i;
    }

    merged->keys[merged->n] = parent->keys[sep];
    merged->n++;

    for (int j = 0; j < absorbed->n; j++)
        merged->keys[merged->n + j] = absorbed->keys[j];
    for (int j = 0; j <= absorbed->n; j++)
        merged->children[merged->n + j] = absorbed->children[j];
    merged->n += absorbed->n;

    for (int j = sep; j < parent->n - 1; j++)
        parent->keys[j] = parent->keys[j + 1];
    for (int j = sep + 1; j < parent->n; j++)
        parent->children[j] = parent->children[j + 1];
    parent->n--;

    free(absorbed);
}
```

In summary, node merges are completed in three steps, assuming the element has already been removed: 1. Transfer all elements from the right node to the left node. 2. Remove or demote the right node pointer from the parent, depending on whether it's a nonleaf merge. 3. Delete the right node.

In summary, while binary search trees may share similar complexity traits, they are not ideal for disk storage due to low fanout and the frequent relocations and pointer updates required for balancing. B-Trees address these issues by storing more items in each node (high fanout) and requiring less frequent balancing operations.
