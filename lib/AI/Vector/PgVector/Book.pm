use v5.40.0;

use experimental 'class';

class AI::Vector::PgVector::Book {
    use overload '""' => 'to_string', fallback => 1;

    field $book_id :param :reader;
    field $genre :param :reader;
    field $title :param :reader;
    field $summary :param :reader;
    field $distance :param :reader = 0;

    method to_string () {
        return <<~"END";
        $title ($genre) Distance: $distance

        Summary: $summary
        END
    }
}

__END__

=head1 NAME

AI::Vector::PgVector::Book - A simple book object

=head1 SYNOPSIS

    use AI::Vector::PgVector::Book;

    my $book = AI::Vector::PgVector::Book->new(
        book_id => 1,
        genre   => 'Science Fiction',
        title   => 'The Hitchhiker\'s Guide to the Galaxy',
        summary => 'The misadventures of Arthur Dent, an Englishman who escapes the destruction of Earth only to face the absurdities of the universe.'
    );

    say $book->to_string;

=head1 DESCRIPTION

This is a simple read-only object to represent a book for the purposes of the
PgVector AI module.

=head1 METHODS

=head2 new

Create a new book object.

=head2 to_string

Return a string representation of the book.

=head1 CONSTRUCTOR ATTRIBUTES

=head2 book_id

The unique identifier for the book. Required.

=head2 genre

The genre of the book. Required.

=head2 title

The title of the book. Required.

=head2 summary

A brief summary of the book. Required.

=head2 distance

The distance of the book from a query. Optional.
