pub fn add(a: i32, b: i32) -> i32 {
    // intentional bug: returns wrong value to make tests fail
    a - b
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_works() {
        assert_eq!(add(2, 2), 4); // will fail: 2 - 2 = 0
    }
}
