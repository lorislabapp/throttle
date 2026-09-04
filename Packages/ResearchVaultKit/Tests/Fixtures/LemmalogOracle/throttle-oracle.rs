use lemmalog::{Ann, Engine, Value};

struct Generator { state: u64 }

impl Generator {
    fn next(&mut self, upper: usize) -> usize {
        self.state = self.state
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        (self.state % upper as u64) as usize
    }
}

fn main() {
    let count: usize = std::env::args().nth(1)
        .and_then(|value| value.parse().ok()).unwrap_or(10_000);
    assert!((1..=100_000).contains(&count));
    let mut generator = Generator { state: 0x5448_524f_5454_4c45 };
    for program_index in 0..count {
        let mut base = Vec::new();
        for _ in 0..12 {
            base.push((generator.next(3), generator.next(8)));
        }
        let mut rules = Vec::new();
        for _ in 0..8 {
            let head = 3 + generator.next(3);
            let left = generator.next(6);
            let has_second = generator.next(2) == 1;
            let right = generator.next(6);
            rules.push((head, left, has_second, right));
        }

        let mut engine = Engine::new();
        let program = rules.iter().map(|(head, left, has_second, right)| {
            if *has_second {
                format!("p{head}(X) :- p{left}(X), p{right}(X).")
            } else {
                format!("p{head}(X) :- p{left}(X).")
            }
        }).collect::<Vec<_>>().join("\n");
        engine.install_program(&program).expect("valid positive program");
        let constants: Vec<Value> = (0..8).map(|index| engine.sym(&format!("c{index}"))).collect();
        for (predicate, constant) in base {
            engine.declare(&format!("p{predicate}"), &[constants[constant]], Ann::unit());
        }
        engine.run();
        let mut canonical = Vec::new();
        for predicate in 0..6 {
            for (arguments, _) in engine.query(&format!("p{predicate}"), &[]) {
                let constant = constants.iter().position(|value| *value == arguments[0])
                    .expect("known generated constant");
                canonical.push(format!("p{predicate}(c{constant})"));
            }
        }
        canonical.sort();
        canonical.dedup();
        println!("{program_index}:{}", canonical.join(","));
    }
}
